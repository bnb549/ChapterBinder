import Foundation

struct ExportProgress: Sendable {
    var fraction: Double
    var message: String
}

enum FFmpegExportService {
    static func export(
        project: BookProject,
        destination: URL,
        onProgress: @escaping @Sendable (ExportProgress) -> Void
    ) async throws -> [URL] {
        try Task.checkCancellation()
        let ffmpeg = try HelperBinary.ffmpeg.url()
        _ = try HelperBinary.ffprobe.url()

        guard !project.tracks.isEmpty else {
            throw AppError.exportFailed("This book has no source tracks.")
        }
        for track in project.tracks {
            if !FileManager.default.fileExists(atPath: track.path) {
                throw AppError.fileMissing(track.path)
            }
        }

        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        let volumes = planVolumes(project)
        var outputs: [URL] = []
        for (index, volume) in volumes.enumerated() {
            try Task.checkCancellation()
            let url = volumeURL(base: destination, index: index, count: volumes.count, project: project)
            onProgress(ExportProgress(
                fraction: Double(index) / Double(max(volumes.count, 1)),
                message: volumes.count > 1 ? "Volume \(index + 1) of \(volumes.count)" : "Exporting"
            ))
            try await exportVolume(
                project: volume,
                destination: url,
                ffmpeg: ffmpeg,
                overall: { p in
                    let base = Double(index) / Double(volumes.count)
                    let span = 1.0 / Double(volumes.count)
                    onProgress(ExportProgress(fraction: base + p.fraction * span, message: p.message))
                }
            )
            outputs.append(url)
        }
        return outputs
    }

    private static func exportVolume(
        project: BookProject,
        destination: URL,
        ffmpeg: URL,
        overall: @escaping @Sendable (ExportProgress) -> Void
    ) async throws {
        let fm = FileManager.default
        let temp = tempDirectory(near: destination)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: temp)
        }

        let settings = project.encodeSettings
        let canRemux = canRemuxCopy(project: project, settings: settings)
        let audioURL: URL

        if canRemux && project.tracks.count == 1 {
            overall(ExportProgress(fraction: 0.2, message: "Remuxing (no re-encode)"))
            audioURL = project.tracks[0].url
        } else if canRemux {
            overall(ExportProgress(fraction: 0.15, message: "Concatenating AAC (stream copy)"))
            audioURL = try await concat(
                files: project.tracks.map(\.url),
                ffmpeg: ffmpeg,
                temp: temp,
                copy: true,
                overall: overall
            )
        } else {
            let encoded = try await encodeAll(
                project: project,
                ffmpeg: ffmpeg,
                temp: temp,
                settings: settings,
                overall: overall
            )
            overall(ExportProgress(fraction: 0.72, message: "Joining encoded tracks"))
            audioURL = try await concat(
                files: encoded,
                ffmpeg: ffmpeg,
                temp: temp,
                copy: true,
                overall: { p in
                    overall(ExportProgress(fraction: 0.72 + p.fraction * 0.1, message: p.message))
                }
            )
        }

        let metaURL = temp.appendingPathComponent("ffmetadata.txt")
        try FFMetadataBuilder.build(project: project, includeGlobalTags: true)
            .data(using: .utf8)?
            .write(to: metaURL, options: .atomic)

        var coverURL: URL?
        if let path = project.coverPath, fm.fileExists(atPath: path) {
            coverURL = URL(fileURLWithPath: path)
        }

        overall(ExportProgress(fraction: 0.86, message: "Writing chaptered \(project.outputContainer.label)"))
        try await mux(
            audio: audioURL,
            metadata: metaURL,
            cover: coverURL,
            destination: destination,
            ffmpeg: ffmpeg,
            project: project
        )

        overall(ExportProgress(fraction: 0.95, message: "Verifying chapters"))
        try await verify(output: destination, project: project)
        overall(ExportProgress(fraction: 1, message: "Done"))
    }

    static func canRemuxCopy(project: BookProject, settings: EncodeSettings) -> Bool {
        if project.loudnessNormalize || project.stripSilence { return false }
        guard project.tracks.allSatisfy(\.isAAC) else { return false }
        if settings.keepSource { return true }
        return project.tracks.allSatisfy { track in
            (settings.channels == 0 || track.channels == settings.channels)
                && (settings.sampleRate == 0 || track.sampleRate == settings.sampleRate)
        }
    }

    private static func encodeAll(
        project: BookProject,
        ffmpeg: URL,
        temp: URL,
        settings: EncodeSettings,
        overall: @escaping @Sendable (ExportProgress) -> Void
    ) async throws -> [URL] {
        let encodedDir = temp.appendingPathComponent("encoded", isDirectory: true)
        try FileManager.default.createDirectory(at: encodedDir, withIntermediateDirectories: true)

        let filters = audioFilters(project: project)
        var outputs = Array(repeating: URL(fileURLWithPath: "/dev/null"), count: project.tracks.count)
        let total = max(project.tracks.count, 1)

        try await withThrowingTaskGroup(of: (Int, URL).self) { group in
            var inFlight = 0
            var next = 0
            let limit = 4

            func enqueue(_ index: Int) {
                let track = project.tracks[index]
                let out = encodedDir.appendingPathComponent(String(format: "%04d.m4a", index))
                group.addTask {
                    try await encodeOne(
                        ffmpeg: ffmpeg,
                        input: track.url,
                        output: out,
                        settings: settings,
                        filters: filters,
                        duration: track.duration
                    )
                    return (index, out)
                }
            }

            while next < project.tracks.count && inFlight < limit {
                enqueue(next)
                next += 1
                inFlight += 1
            }

            var finished = 0
            for try await (index, url) in group {
                outputs[index] = url
                finished += 1
                inFlight -= 1
                overall(ExportProgress(
                    fraction: 0.05 + (Double(finished) / Double(total)) * 0.65,
                    message: "Encoding track \(finished) of \(total)"
                ))
                if next < project.tracks.count {
                    enqueue(next)
                    next += 1
                    inFlight += 1
                }
            }
        }
        return outputs
    }

    private static func encodeOne(
        ffmpeg: URL,
        input: URL,
        output: URL,
        settings: EncodeSettings,
        filters: String?,
        duration: TimeInterval
    ) async throws {
        var args = [
            "-y", "-hide_banner", "-nostats",
            "-progress", "pipe:1",
            "-i", input.path,
            "-vn",
            "-c:a", "aac",
            "-profile:a", "aac_low",
            "-b:a", "\(max(24, settings.bitrateKbps))k",
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
        _ = duration
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
            "-movflags", "+faststart+use_metadata_tags",
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

    static func verify(output: URL, project: BookProject) async throws {
        let probe = try await ProbeService.probeWithFFProbe(url: output)
        if probe.chapters.count != project.chapters.count {
            throw AppError.verificationFailed(
                "Expected \(project.chapters.count) chapters, ffprobe found \(probe.chapters.count). Apple Books will not show a chapter list."
            )
        }
        if probe.duration + 1 < project.totalDuration * 0.95 {
            throw AppError.verificationFailed(
                "Output duration \(TimeFormatting.clock(probe.duration)) is shorter than source \(TimeFormatting.clock(project.totalDuration))."
            )
        }
        if project.coverPath != nil && !probe.hasCover {
            throw AppError.verificationFailed("Cover art was not embedded.")
        }
    }

    private static func planVolumes(_ project: BookProject) -> [BookProject] {
        let maxBytes = project.splitMaxBytes ?? 0
        let maxSeconds = (project.splitMaxHours ?? 0) * 3600
        if maxBytes <= 0 && maxSeconds <= 0 { return [project] }
        if project.chapters.isEmpty { return [project] }

        let bitrate = max(project.encodeSettings.bitrateKbps, 64)
        func estimatedBytes(_ duration: TimeInterval) -> Int64 {
            Int64(duration * Double(bitrate) * 1000 / 8)
        }

        var volumes: [BookProject] = []
        var current = project
        current.chapters = []
        var accTime: TimeInterval = 0
        var accBytes: Int64 = 0

        func flush() {
            guard !current.chapters.isEmpty else { return }
            var copy = current
            let part = volumes.count + 1
            copy.title = "\(project.displayTitle) – Part \(part)"
            copy.recomputeTimeline()
            volumes.append(copy)
            current.chapters = []
            accTime = 0
            accBytes = 0
        }

        for chapter in project.chapters {
            let nextTime = accTime + chapter.duration
            let nextBytes = accBytes + estimatedBytes(chapter.duration)
            let overTime = maxSeconds > 0 && accTime > 0 && nextTime > maxSeconds
            let overBytes = maxBytes > 0 && accBytes > 0 && nextBytes > maxBytes
            if overTime || overBytes {
                flush()
            }
            current.chapters.append(chapter)
            accTime += chapter.duration
            accBytes += estimatedBytes(chapter.duration)
        }
        flush()
        return volumes.isEmpty ? [project] : volumes
    }

    private static func volumeURL(base: URL, index: Int, count: Int, project: BookProject) -> URL {
        if count <= 1 { return base }
        let name = base.deletingPathExtension().lastPathComponent
        let ext = base.pathExtension
        return base.deletingLastPathComponent()
            .appendingPathComponent("\(name) - Part \(index + 1).\(ext)")
    }

    private static func tempDirectory(near destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(".__chapterbinder_\(UUID().uuidString)", isDirectory: true)
    }
}
