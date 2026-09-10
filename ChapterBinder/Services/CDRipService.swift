import Foundation

protocol CDRipServicing: Sendable {
    func readTOC(from disc: DetectedDisc) async throws -> CDTOC
    func rip(
        disc: DetectedDisc,
        tracks: [Int],
        quality: RipQuality,
        destination: URL,
        onProgress: @escaping @Sendable (RipProgress) -> Void
    ) async throws -> [URL]
}

struct MockCDRipper: CDRipServicing {
    func readTOC(from disc: DetectedDisc) async throws -> CDTOC {
        disc.toc ?? MockTOC.make(bsdName: disc.bsdName)
    }

    func rip(
        disc: DetectedDisc,
        tracks: [Int],
        quality: RipQuality,
        destination: URL,
        onProgress: @escaping @Sendable (RipProgress) -> Void
    ) async throws -> [URL] {
        let toc = try await readTOC(from: disc)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var urls: [URL] = []
        let selected = toc.tracks.filter { tracks.contains($0.number) }
        for (i, track) in selected.enumerated() {
            try Task.checkCancellation()
            onProgress(RipProgress(
                trackNumber: track.number,
                trackCount: selected.count,
                fraction: Double(i) / Double(max(selected.count, 1)),
                message: "Mock rip track \(track.number)",
                skipped: []
            ))
            let url = destination.appendingPathComponent(String(format: "track%02d.wav", track.number))
            try WAVWriter.writeSilence(duration: min(track.duration, 2.0), to: url)
            urls.append(url)
            try await Task.sleep(for: .milliseconds(120))
        }
        onProgress(RipProgress(
            trackNumber: selected.last?.number ?? 0,
            trackCount: selected.count,
            fraction: 1,
            message: "Mock rip complete",
            skipped: []
        ))
        return urls
    }
}

struct ParanoiaCDRipper: CDRipServicing {
    func readTOC(from disc: DetectedDisc) async throws -> CDTOC {
        if disc.isMock { return try await MockCDRipper().readTOC(from: disc) }
        if let existing = disc.toc, !existing.tracks.isEmpty { return existing }

        if let binary = HelperBinary.cdparanoia.optionalURL() {
            let args = ["-Q"] + deviceArgs(bsdName: disc.bsdName)
            let result = try await ProcessRunner.run(executable: binary, arguments: args)
            let parsed = parseParanoiaTOC(result.stderr + "\n" + result.stdout, bsdName: disc.bsdName)
            if !parsed.tracks.isEmpty { return parsed }
        }

        if let volume = disc.volumeURL {
            return tocFromMountedAudioCD(volume, bsdName: disc.bsdName)
        }

        throw AppError.ripFailed("Could not read the disc table of contents.")
    }

    func rip(
        disc: DetectedDisc,
        tracks: [Int],
        quality: RipQuality,
        destination: URL,
        onProgress: @escaping @Sendable (RipProgress) -> Void
    ) async throws -> [URL] {
        if disc.isMock {
            return try await MockCDRipper().rip(
                disc: disc,
                tracks: tracks,
                quality: quality,
                destination: destination,
                onProgress: onProgress
            )
        }

        guard let binary = HelperBinary.cdparanoia.optionalURL() else {
            throw AppError.helperMissing("cdparanoia")
        }

        let toc = try await readTOC(from: disc)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        var urls: [URL] = []
        var skipped: [Int] = []
        let selected = toc.tracks.filter { tracks.contains($0.number) }

        for (i, track) in selected.enumerated() {
            try Task.checkCancellation()
            onProgress(RipProgress(
                trackNumber: track.number,
                trackCount: selected.count,
                fraction: Double(i) / Double(max(selected.count, 1)),
                message: "Ripping track \(track.number)",
                skipped: skipped
            ))

            let url = destination.appendingPathComponent(String(format: "track%02d.wav", track.number))
            var args = quality.cdparanoiaFlags
            args += deviceArgs(bsdName: disc.bsdName)
            args += ["-w", "\(track.number)", url.path]

            do {
                let result = try await ProcessRunner.run(executable: binary, arguments: args)
                if result.exitCode != 0 || !FileManager.default.fileExists(atPath: url.path) {
                    skipped.append(track.number)
                    continue
                }
                urls.append(url)
            } catch is CancellationError {
                throw AppError.cancelled
            } catch {
                skipped.append(track.number)
            }
        }

        if urls.isEmpty {
            throw AppError.ripFailed("Every selected track failed to rip.")
        }
        onProgress(RipProgress(
            trackNumber: selected.last?.number ?? 0,
            trackCount: selected.count,
            fraction: 1,
            message: skipped.isEmpty ? "Rip complete" : "Rip complete with skipped tracks \(skipped)",
            skipped: skipped
        ))
        return urls
    }

    private func deviceArgs(bsdName: String) -> [String] {
        if bsdName.hasPrefix("mock") { return [] }
        let dev = bsdName.hasPrefix("/dev/") ? bsdName : "/dev/\(bsdName)"
        return ["-d", dev]
    }

    private func parseParanoiaTOC(_ text: String, bsdName: String) -> CDTOC {
        // Typical: "  1.    150    15234   00:02:00"
        let pattern = #"^\s*(\d+)\.\s+(\d+)\s+(\d+)\s+(\d+):(\d+):(\d+)"#
        let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        var tracks: [CDTrackInfo] = []
        let ns = text as NSString
        regex?.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match,
                  let nRange = Range(match.range(at: 1), in: text),
                  let number = Int(text[nRange])
            else { return }
            var duration: TimeInterval = 0
            if match.numberOfRanges > 6,
               let mm = Range(match.range(at: 4), in: text),
               let ss = Range(match.range(at: 5), in: text),
               let ff = Range(match.range(at: 6), in: text),
               let m = Double(text[mm]), let s = Double(text[ss]), let f = Double(text[ff]) {
                duration = m * 60 + s + f / 75
            }
            tracks.append(CDTrackInfo(number: number, start: 0, duration: duration, title: String(format: "Track %02d", number)))
        }
        var cursor: TimeInterval = 0
        for i in tracks.indices {
            tracks[i].start = cursor
            cursor += tracks[i].duration
        }
        return CDTOC(bsdName: bsdName, discID: nil, tracks: tracks, raw: text)
    }

    private func tocFromMountedAudioCD(_ volume: URL, bsdName: String) -> CDTOC {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: volume, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let audio = NaturalSort.sorted(files.filter { ["cda", "aiff", "aif", "wav"].contains($0.pathExtension.lowercased()) }) { $0.lastPathComponent }
        var tracks: [CDTrackInfo] = []
        var start: TimeInterval = 0
        for (i, file) in audio.enumerated() {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            // Audio CD is 176400 bytes/sec stereo 16-bit 44.1 kHz; .cda files are stubs, so fall back.
            let duration = size > 10_000 ? TimeInterval(size) / 176_400 : 180
            tracks.append(CDTrackInfo(number: i + 1, start: start, duration: duration, title: file.deletingPathExtension().lastPathComponent))
            start += duration
        }
        return CDTOC(bsdName: bsdName, discID: nil, tracks: tracks, raw: volume.path)
    }
}

enum CDRipperFactory {
    static func make(for disc: DetectedDisc) -> any CDRipServicing {
        if disc.isMock { return MockCDRipper() }
        return ParanoiaCDRipper()
    }
}
