import Foundation

struct ImportPlan: Sendable {
    var tracks: [SourceTrack]
    var coverCandidate: URL?
    var cueChapters: [EmbeddedChapter]
    var textChapters: [EmbeddedChapter]
    var suggestedTitle: String?
    var suggestedAuthor: String?
    var suggestedYear: Int?
    var isSingleAudiobookFile: Bool
    var embeddedChapters: [EmbeddedChapter]
}

enum ImportService {
    static func collectAudioFiles(from urls: [URL]) -> [URL] {
        var files: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                    for case let file as URL in enumerator {
                        if AudioFileType.isAudio(file) {
                            files.append(file)
                        }
                    }
                }
            } else if AudioFileType.isAudio(url) {
                files.append(url)
            }
        }
        return NaturalSort.sorted(files) { $0.path }
    }

    nonisolated static func rejectDRM(in urls: [URL]) throws {
        let fm = FileManager.default
        func fail(_ url: URL) -> Error {
            AppError.importFailed(
                "“\(url.lastPathComponent)” is an Audible file. ChapterBinder does not unlock DRM. Import a DRM-free AAC, MP3, WAV, FLAC, or M4B instead."
            )
        }
        for url in urls {
            if AudioFileType.isAudibleDRM(url) { throw fail(url) }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for case let file as URL in enumerator where AudioFileType.isAudibleDRM(file) {
                throw fail(file)
            }
        }
    }

    static func makePlan(from urls: [URL]) async throws -> ImportPlan {
        try rejectDRM(in: urls)
        let files = collectAudioFiles(from: urls)
        guard !files.isEmpty else {
            throw AppError.importFailed("No audio files found. Drop MP3, M4A, M4B, AAC, WAV, AIFF, FLAC, or CAF.")
        }

        var tracks: [SourceTrack] = []
        var coverFromAudio: URL?
        var suggestedTitle: String?
        var suggestedAuthor: String?
        var suggestedYear: Int?
        var embeddedChapters: [EmbeddedChapter] = []

        for (index, file) in files.enumerated() {
            let started = file.startAccessingSecurityScopedResource()
            defer { if started { file.stopAccessingSecurityScopedResource() } }
            let probe = try await ProbeService.probe(url: file)
            let disc = DiscFolder.discIndex(in: file.path) ?? 1
            let title = probe.title?.isEmpty == false ? probe.title! : file.deletingPathExtension().lastPathComponent
            let bookmark = SecurityScope.bookmark(for: file)

            let track = SourceTrack(
                path: file.path,
                bookmark: bookmark,
                discIndex: disc,
                trackIndex: probe.trackNumber ?? (index + 1),
                duration: probe.duration,
                originalTitle: title,
                codec: probe.codec,
                channels: probe.channels,
                sampleRate: probe.sampleRate,
                bitrate: probe.bitrate,
                isRip: false,
                ripOK: true,
                embeddedTrackNumber: probe.trackNumber,
                tags: probe.tags,
                hasEmbeddedCover: probe.hasCover
            )
            tracks.append(track)

            if suggestedTitle == nil, let album = probe.album, !album.isEmpty {
                suggestedTitle = album
            }
            if suggestedAuthor == nil {
                suggestedAuthor = probe.albumArtist ?? probe.artist
            }
            if suggestedYear == nil {
                suggestedYear = probe.year
            }
            if coverFromAudio == nil, probe.hasCover {
                coverFromAudio = file
            }
            if files.count == 1 {
                embeddedChapters = probe.chapters
            }
        }

        tracks = sortTracks(tracks, mode: .naturalFilename)

        let folders = urls.filter { url in
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            return isDir.boolValue
        }
        if suggestedTitle == nil {
            suggestedTitle = folders.first?.lastPathComponent ?? files.first?.deletingLastPathComponent().lastPathComponent
        }

        let coverCandidate = largestImage(in: folders) ?? coverFromAudio
        let cue = parseSiblingCues(around: files)
        let textChapters = parseSiblingChapterLists(around: files)

        return ImportPlan(
            tracks: tracks,
            coverCandidate: coverCandidate,
            cueChapters: cue,
            textChapters: textChapters,
            suggestedTitle: suggestedTitle,
            suggestedAuthor: suggestedAuthor,
            suggestedYear: suggestedYear,
            isSingleAudiobookFile: files.count == 1 && ["m4b", "m4a"].contains(files[0].pathExtension.lowercased()),
            embeddedChapters: embeddedChapters
        )
    }

    static func sortTracks(_ tracks: [SourceTrack], mode: TrackSortMode) -> [SourceTrack] {
        switch mode {
        case .naturalFilename:
            return NaturalSort.sorted(tracks) { String(format: "%03d-%@", $0.discIndex, $0.path) }
        case .embeddedTrack:
            return tracks.sorted { a, b in
                if a.discIndex != b.discIndex { return a.discIndex < b.discIndex }
                let an = a.embeddedTrackNumber ?? a.trackIndex
                let bn = b.embeddedTrackNumber ?? b.trackIndex
                if an != bn { return an < bn }
                return NaturalSort.compare(a.filename, b.filename) == .orderedAscending
            }
        case .duration:
            return tracks.sorted { $0.duration < $1.duration }
        }
    }

    static func largestImage(in folders: [URL]) -> URL? {
        let imageExt = Set(["jpg", "jpeg", "png", "webp", "tif", "tiff"])
        var best: (URL, Int64)?
        let fm = FileManager.default
        for folder in folders {
            if let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) {
                for case let file as URL in enumerator {
                    guard imageExt.contains(file.pathExtension.lowercased()) else { continue }
                    let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                    if best == nil || size > best!.1 {
                        best = (file, size)
                    }
                }
            }
        }
        return best?.0
    }

    private static func parseSiblingCues(around files: [URL]) -> [EmbeddedChapter] {
        let dirs = Set(files.map { $0.deletingLastPathComponent() })
        for dir in dirs {
            if let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                if let cue = items.first(where: { $0.pathExtension.lowercased() == "cue" }),
                   let text = try? String(contentsOf: cue, encoding: .utf8) {
                    let chapters = ChapterListIO.parseCUE(text)
                    if !chapters.isEmpty { return chapters }
                }
            }
        }
        return []
    }

    private static func parseSiblingChapterLists(around files: [URL]) -> [EmbeddedChapter] {
        let names = ["chapters.txt", "chapters.ffmeta", "ffmetadata.txt", "chapter.txt"]
        let dirs = Set(files.map { $0.deletingLastPathComponent() })
        for dir in dirs {
            for name in names {
                let url = dir.appendingPathComponent(name)
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    let chapters = ChapterListIO.parse(text)
                    if !chapters.isEmpty { return chapters }
                }
            }
        }
        return []
    }
}
