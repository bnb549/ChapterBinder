import Foundation

nonisolated struct ExportProgress: Sendable {
    var fraction: Double
    var message: String
}

nonisolated enum FFmpegExportService {
    /// Developer ID fallback. The file is stamped after ffmpeg closes it.
    static func exportVolume(
        project: BookProject,
        destination: URL,
        workingDirectory: URL,
        cover: Data?,
        onProgress: @escaping @Sendable (ExportProgress) -> Void
    ) async throws -> ChapterlineReport {
        try Task.checkCancellation()
        let ffmpeg = try HelperBinary.ffmpeg.url()
        let fm = FileManager.default
        let temp = workingDirectory
        var discard = false
        defer {
            if discard || Task.isCancelled {
                try? fm.removeItem(at: temp)
            }
        }

        let settings = project.encodeSettings
        let slices = ExportPlanner.slices(for: project)
        let files = slices.compactMap { project.track(id: $0.trackID)?.url }
        let canRemux = ExportPlanner.canStreamCopy(project: project, settings: settings)
        let audioURL: URL

        if canRemux && files.count == 1 {
            onProgress(ExportProgress(fraction: 0.2, message: "Remuxing (no re-encode)"))
            audioURL = files[0]
        } else if canRemux {
            onProgress(ExportProgress(fraction: 0.15, message: "Concatenating AAC (stream copy)"))
            audioURL = try await concat(
                files: files,
                ffmpeg: ffmpeg,
                temp: temp,
                copy: true,
                overall: onProgress
            )
        } else {
            let encoded = try await encodeSlices(
                slices: slices,
                project: project,
                ffmpeg: ffmpeg,
                temp: temp,
                settings: settings,
                overall: onProgress
            )
            onProgress(ExportProgress(fraction: 0.72, message: "Joining encoded tracks"))
            audioURL = try await concat(
                files: encoded,
                ffmpeg: ffmpeg,
                temp: temp,
                copy: true,
                overall: { p in
                    onProgress(ExportProgress(fraction: 0.72 + p.fraction * 0.1, message: p.message))
                }
            )
        }

        let metaURL = temp.appendingPathComponent("ffmetadata.txt")
        try FFMetadataBuilder.build(project: project, includeGlobalTags: true)
            .data(using: .utf8)?
            .write(to: metaURL, options: .atomic)

        var coverURL: URL?
        if let cover, !cover.isEmpty {
            let file = temp.appendingPathComponent("cover.jpg")
            try cover.write(to: file, options: .atomic)
            coverURL = file
        }

        onProgress(ExportProgress(fraction: 0.86, message: "Muxing audio"))
        let muxed = temp.appendingPathComponent("muxed.m4a")
        try await mux(
            audio: audioURL,
            metadata: metaURL,
            cover: coverURL,
            destination: muxed,
            ffmpeg: ffmpeg,
            project: project
        )

        let marks = try ChapterTimeline.marks(for: project)
        onProgress(ExportProgress(fraction: 0.92, message: "Writing moov/udta/chpl and tref/chap"))
        try M4BChapterStamper.stamp(
            source: muxed,
            destination: destination,
            chapters: marks,
            tags: StampTags(
                title: project.displayTitle,
                artist: project.author,
                album: project.displayTitle,
                cover: cover
            )
        )
        onProgress(ExportProgress(fraction: 0.97, message: "Checking moov/udta/chpl and tref/chap"))
        let report: ChapterlineReport
        do {
            report = try await ChapterlineVerifier.verify(
                url: destination,
                marks: marks,
                expectedDuration: marks.last?.end ?? project.totalDuration,
                hadCover: cover != nil
            )
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
        discard = true
        onProgress(ExportProgress(fraction: 1, message: report.line))
        return report
    }

    static func canRemuxCopy(project: BookProject, settings: EncodeSettings) -> Bool {
        ExportPlanner.canStreamCopy(project: project, settings: settings)
    }

    private static func encodeOne(
        ffmpeg: URL,
        input: URL,
        output: URL,
        settings: EncodeSettings,
        filters: String?,
        start: TimeInterval,
        duration: TimeInterval
    ) async throws {
        let bitrate = settings.bitrateKbps > 0 ? settings.bitrateKbps : 64
        var args = [
            "-y", "-hide_banner", "-nostats",
            "-progress", "pipe:1",
            "-ss", String(format: "%.3f", max(0, start)),
            "-i", input.path,
            "-t", String(format: "%.3f", duration),
            "-vn",
            "-c:a", "aac",
            "-profile:a", "aac_low",
            "-b:a", "\(max(24, bitrate))k",
        ]
        if settings.channels > 0 {
            args += ["-ac", "\(settings.channels)"]
        }
        if settings.sampleRate > 0 {
            args += ["-ar", "\(settings.sampleRate)"]
        }
        if let filters {
            args += ["-af", filters]
        }
        args.append(output.path)

        let result = try await ProcessRunner.run(executable: ffmpeg, arguments: args)
        if result.exitCode != 0 {
            throw AppError.exportFailed(result.stderr.suffix(800).description)
        }
    }

    private static func audioFilters(project: BookProject) -> String? {
        var parts: [String] = []
        if project.stripSilence {
            parts.append("silenceremove=start_periods=1:start_silence=0.25:start_threshold=-40dB:stop_periods=1:stop_silence=0.25:stop_threshold=-40dB")
        }
        if project.loudnessNormalize {
            parts.append("loudnorm=I=-18:TP=-1.5:LRA=11")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ",")
    }

    private static func concat(
        files: [URL],
        ffmpeg: URL,
        temp: URL,
        copy: Bool,
        overall: @escaping @Sendable (ExportProgress) -> Void
    ) async throws -> URL {
        let list = temp.appendingPathComponent("concat.txt")
        let body = files.map { file in
            let path = file.path.replacingOccurrences(of: "'", with: "'\\''")
            return "file '\(path)'"
        }.joined(separator: "\n")
        try body.write(to: list, atomically: true, encoding: .utf8)
        let out = temp.appendingPathComponent("concat.m4a")
        var args = [
            "-y", "-hide_banner", "-nostats",
            "-progress", "pipe:1",
            "-f", "concat", "-safe", "0",
            "-i", list.path,
        ]
        if copy {
            args += ["-c", "copy"]
        } else {
            args += ["-c:a", "aac"]
        }
        args += ["-movflags", "+faststart", out.path]
        overall(ExportProgress(fraction: 0.4, message: "Concatenating"))
        let result = try await ProcessRunner.run(executable: ffmpeg, arguments: args)
        if result.exitCode != 0 {
            throw AppError.exportFailed("Concat failed: \(result.stderr.suffix(600))")
        }
        return out
    }

    private static func mux(
        audio: URL,
        metadata: URL,
        cover: URL?,
        destination: URL,
        ffmpeg: URL,
        project: BookProject
    ) async throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        var args = [
            "-y", "-hide_banner", "-nostats",
            "-i", audio.path,
            "-i", metadata.path,
        ]
        if let cover {
            args += ["-i", cover.path]
        }
        args += ["-map", "0:a:0"]
        if cover != nil {
            args += ["-map", "2:v:0", "-c:v", "mjpeg", "-disposition:v:0", "attached_pic"]
        }
        args += [
            "-map_metadata", "1",
            "-c:a", "copy",
            "-f", "mp4",
            "-brand", "M4B",
            "-movflags", "+faststart",
            "-metadata", "media_type=2",
            "-metadata", "title=\(project.displayTitle)",
            "-metadata", "artist=\(project.author)",
            "-metadata", "album=\(project.displayTitle)",
            "-metadata", "album_artist=\(project.author)",
            "-metadata", "genre=\(project.genre.isEmpty ? "Audiobook" : project.genre)",
        ]
        if !project.narrator.isEmpty {
            args += ["-metadata", "composer=\(project.narrator)"]
        }
        if !project.description.isEmpty {
            args += ["-metadata", "description=\(project.description)"]
            args += ["-metadata", "comment=\(project.comment.isEmpty ? project.description : project.comment)"]
        }
        if let year = project.year {
            args += ["-metadata", "date=\(year)"]
        }
        if !project.series.isEmpty {
            args += ["-metadata", "series=\(project.series)"]
            args += ["-metadata", "show=\(project.series)"]
        }
        if !project.seriesPart.isEmpty {
            args += ["-metadata", "series-part=\(FilenameSanitizer.paddedSeriesPart(project.seriesPart))"]
        }
        args.append(destination.path)

        let result = try await ProcessRunner.run(executable: ffmpeg, arguments: args)
        if result.exitCode != 0 {
            throw AppError.exportFailed("Mux failed: \(result.stderr.suffix(800))")
        }
    }

    private static func encodeSlices(
        slices: [AudioSlice],
        project: BookProject,
        ffmpeg: URL,
        temp: URL,
        settings: EncodeSettings,
        overall: @escaping @Sendable (ExportProgress) -> Void
    ) async throws -> [URL] {
        let encodedDir = temp.appendingPathComponent("encoded", isDirectory: true)
        try FileManager.default.createDirectory(at: encodedDir, withIntermediateDirectories: true)
        let filters = audioFilters(project: project)
        var outputs: [URL] = []
        let total = max(slices.count, 1)
        for (index, slice) in slices.enumerated() {
            try Task.checkCancellation()
            guard let track = project.track(id: slice.trackID) else { continue }
            let out = encodedDir.appendingPathComponent(String(format: "%04d.m4a", index))
            try await encodeOne(
                ffmpeg: ffmpeg,
                input: track.url,
                output: out,
                settings: settings,
                filters: filters,
                start: slice.start,
                duration: max(0.05, slice.end - slice.start)
            )
            outputs.append(out)
            overall(ExportProgress(
                fraction: 0.05 + (Double(index + 1) / Double(total)) * 0.65,
                message: "Encoding track \(index + 1) of \(total)"
            ))
        }
        return outputs
    }
}
