import Foundation

enum TrackSortMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case naturalFilename
    case embeddedTrack
    case duration

    var id: String { rawValue }

    var label: String {
        switch self {
        case .naturalFilename: "Filename (natural)"
        case .embeddedTrack: "Embedded track number"
        case .duration: "Duration"
        }
    }
}

enum RipStatus: String, Codable, Sendable {
    case idle
    case ripping
    case complete
    case failed
    case skipped
}

struct Disc: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var index: Int
    var musicBrainzId: String?
    var rawTOC: String
    var ripStatus: RipStatus
    var ripError: String?
    var ripProgress: Double

    init(
        id: UUID = UUID(),
        index: Int,
        musicBrainzId: String? = nil,
        rawTOC: String = "",
        ripStatus: RipStatus = .idle,
        ripError: String? = nil,
        ripProgress: Double = 0
    ) {
        self.id = id
        self.index = index
        self.musicBrainzId = musicBrainzId
        self.rawTOC = rawTOC
        self.ripStatus = ripStatus
        self.ripError = ripError
        self.ripProgress = ripProgress
    }
}

struct SourceTrack: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var path: String
    var bookmark: Data?
    var discIndex: Int
    var trackIndex: Int
    var duration: TimeInterval
    var originalTitle: String
    var codec: String
    var channels: Int
    var sampleRate: Int
    var bitrate: Int?
    var isRip: Bool
    var ripOK: Bool
    var embeddedTrackNumber: Int?
    var tags: [String: String]
    var hasEmbeddedCover: Bool

    init(
        id: UUID = UUID(),
        path: String,
        bookmark: Data? = nil,
        discIndex: Int = 1,
        trackIndex: Int = 1,
        duration: TimeInterval = 0,
        originalTitle: String = "",
        codec: String = "",
        channels: Int = 2,
        sampleRate: Int = 44100,
        bitrate: Int? = nil,
        isRip: Bool = false,
        ripOK: Bool = true,
        embeddedTrackNumber: Int? = nil,
        tags: [String: String] = [:],
        hasEmbeddedCover: Bool = false
    ) {
        self.id = id
        self.path = path
        self.bookmark = bookmark
        self.discIndex = discIndex
        self.trackIndex = trackIndex
        self.duration = duration
        self.originalTitle = originalTitle
        self.codec = codec
        self.channels = channels
        self.sampleRate = sampleRate
        self.bitrate = bitrate
        self.isRip = isRip
        self.ripOK = ripOK
        self.embeddedTrackNumber = embeddedTrackNumber
        self.tags = tags
        self.hasEmbeddedCover = hasEmbeddedCover
    }

    var url: URL { URL(fileURLWithPath: path) }
    var filename: String { url.lastPathComponent }
    var isAAC: Bool {
        let c = codec.lowercased()
        if c.contains("alac") { return false }
        return c.contains("aac") || c == "mp4a" || c.contains("mp4a.40")
    }
}

struct Chapter: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var title: String
    /// Source tracks that belong to this chapter, in listen order.
    var trackIDs: [SourceTrack.ID]
    /// Offset into the first track where this chapter starts.
    var startOffset: TimeInterval
    /// End offset into the last track. `nil` means the end of the last track.
    var endOffset: TimeInterval?
    /// Absolute start on the concatenated timeline. Recomputed; do not guess.
    var start: TimeInterval
    /// Duration on the concatenated timeline. Recomputed from actual track durations.
    var duration: TimeInterval

    init(
        id: UUID = UUID(),
        title: String,
        trackIDs: [SourceTrack.ID],
        startOffset: TimeInterval = 0,
        endOffset: TimeInterval? = nil,
        start: TimeInterval = 0,
        duration: TimeInterval = 0
    ) {
        self.id = id
        self.title = title
        self.trackIDs = trackIDs
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.start = start
        self.duration = duration
    }

    var end: TimeInterval { start + duration }
}

struct BookProject: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var title: String
    var sortTitle: String
    var author: String
    var narrator: String
    var description: String
    var year: Int?
    var series: String
    var seriesPart: String
    var genre: String
    var language: String
    var publisher: String
    var copyright: String
    var comment: String
    var coverPath: String?
    var outputPreset: OutputPreset
    var customBitrate: Int
    var customChannels: Int
    var customSampleRate: Int
    var outputContainer: OutputContainer
    var outputPath: String?
    var loudnessNormalize: Bool
    var stripSilence: Bool
    var splitMaxBytes: Int64?
    var splitMaxHours: Double?
    var discs: [Disc]
    var tracks: [SourceTrack]
    var chapters: [Chapter]
    var sortMode: TrackSortMode
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String = "Untitled Book",
        sortTitle: String = "",
        author: String = "",
        narrator: String = "",
        description: String = "",
        year: Int? = nil,
        series: String = "",
        seriesPart: String = "",
        genre: String = "Audiobook",
        language: String = "",
        publisher: String = "",
        copyright: String = "",
        comment: String = "",
        coverPath: String? = nil,
        outputPreset: OutputPreset = .spokenWord,
        customBitrate: Int = 64,
        customChannels: Int = 1,
        customSampleRate: Int = 22050,
        outputContainer: OutputContainer = .m4b,
        outputPath: String? = nil,
        loudnessNormalize: Bool = false,
        stripSilence: Bool = false,
        splitMaxBytes: Int64? = nil,
        splitMaxHours: Double? = nil,
        discs: [Disc] = [],
        tracks: [SourceTrack] = [],
        chapters: [Chapter] = [],
        sortMode: TrackSortMode = .naturalFilename,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.sortTitle = sortTitle
        self.author = author
        self.narrator = narrator
        self.description = description
        self.year = year
        self.series = series
        self.seriesPart = seriesPart
        self.genre = genre
        self.language = language
        self.publisher = publisher
        self.copyright = copyright
        self.comment = comment
        self.coverPath = coverPath
        self.outputPreset = outputPreset
        self.customBitrate = customBitrate
        self.customChannels = customChannels
        self.customSampleRate = customSampleRate
        self.outputContainer = outputContainer
        self.outputPath = outputPath
        self.loudnessNormalize = loudnessNormalize
        self.stripSilence = stripSilence
        self.splitMaxBytes = splitMaxBytes
        self.splitMaxHours = splitMaxHours
        self.discs = discs
        self.tracks = tracks
        self.chapters = chapters
        self.sortMode = sortMode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var totalDuration: TimeInterval {
        chapters.last.map { $0.start + $0.duration } ?? tracks.reduce(0) { $0 + $1.duration }
    }

    var displayTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled Book" : title
    }

    func track(id: SourceTrack.ID) -> SourceTrack? {
        tracks.first { $0.id == id }
    }

    func tracks(for chapter: Chapter) -> [SourceTrack] {
        chapter.trackIDs.compactMap { track(id: $0) }
    }

    func chapter(containing absoluteTime: TimeInterval) -> Chapter? {
        chapters.first { absoluteTime >= $0.start && absoluteTime < $0.end } ?? chapters.last
    }

    /// Maps a book-absolute timestamp onto a source file and an offset inside that file.
    func playbackLocation(at absolute: TimeInterval) -> (track: SourceTrack, offset: TimeInterval, chapter: Chapter)? {
        guard let chapter = chapter(containing: absolute) else { return nil }
        var local = max(0, absolute - chapter.start)
        for (idx, tid) in chapter.trackIDs.enumerated() {
            guard let track = track(id: tid) else { continue }
            let from = idx == 0 ? chapter.startOffset : 0
            let to: TimeInterval
            if idx == chapter.trackIDs.count - 1 {
                to = chapter.endOffset ?? track.duration
            } else {
                to = track.duration
            }
            let slice = max(0, min(to, track.duration) - min(from, track.duration))
            if local < slice || idx == chapter.trackIDs.count - 1 {
                return (track, from + local, chapter)
            }
            local -= slice
        }
        return nil
    }

    func duration(of chapter: Chapter) -> TimeInterval {
        let ids = chapter.trackIDs
        guard !ids.isEmpty else { return 0 }

        if ids.count == 1, let t = track(id: ids[0]) {
            let end = min(chapter.endOffset ?? t.duration, t.duration)
            let start = min(max(0, chapter.startOffset), t.duration)
            return max(0, end - start)
        }

        var total: TimeInterval = 0
        if let first = track(id: ids[0]) {
            total += max(0, first.duration - min(chapter.startOffset, first.duration))
        }
        if ids.count > 2 {
            for id in ids.dropFirst().dropLast() {
                total += track(id: id)?.duration ?? 0
            }
        }
        if let lastID = ids.last, let last = track(id: lastID) {
            let end = min(chapter.endOffset ?? last.duration, last.duration)
            total += max(0, end)
        }
        return total
    }

    mutating func recomputeTimeline() {
        var cursor: TimeInterval = 0
        for i in chapters.indices {
            chapters[i].start = cursor
            chapters[i].duration = duration(of: chapters[i])
            cursor += chapters[i].duration
        }
    }

    mutating func syncTrackOrderFromChapters() {
        var seen = Set<SourceTrack.ID>()
        var ordered: [SourceTrack] = []
        for chapter in chapters {
            for tid in chapter.trackIDs where seen.insert(tid).inserted {
                if let track = track(id: tid) {
                    ordered.append(track)
                }
            }
        }
        for track in tracks where !seen.contains(track.id) {
            ordered.append(track)
        }
        tracks = ordered
    }

    var suggestedFilename: String {
        FilenameSanitizer.filename(from: displayTitle, ext: outputContainer.fileExtension)
    }

    var encodeSettings: EncodeSettings {
        outputPreset.settings(
            customBitrate: customBitrate,
            customChannels: customChannels,
            customSampleRate: customSampleRate
        )
    }
}

struct EncodeSettings: Equatable, Sendable {
    var keepSource: Bool
    var bitrateKbps: Int
    var channels: Int
    var sampleRate: Int
}

enum OutputContainer: String, Codable, CaseIterable, Identifiable, Sendable {
    case m4b
    case m4a

    var id: String { rawValue }
    var fileExtension: String { rawValue }
    var label: String { rawValue.uppercased() }
}

struct EmbeddedChapter: Sendable, Equatable {
    var title: String
    var start: TimeInterval
    var duration: TimeInterval
}

struct ProbeResult: Sendable {
    var duration: TimeInterval
    var codec: String
    var channels: Int
    var sampleRate: Int
    var bitrate: Int?
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var composer: String?
    var narrator: String?
    var trackNumber: Int?
    var discNumber: Int?
    var year: Int?
    var genre: String?
    var comment: String?
    var description: String?
    var hasCover: Bool
    var chapters: [EmbeddedChapter]
    var tags: [String: String]
}

enum AppError: LocalizedError, Sendable {
    case helperMissing(String)
    case probeFailed(String)
    case importFailed(String)
    case exportFailed(String)
    case verificationFailed(String)
    case cancelled
    case ripFailed(String)
    case noOpticalDrive
    case discDisappeared
    case fileMissing(String)

    var errorDescription: String? {
        switch self {
        case .helperMissing(let name):
            "Missing helper “\(name)”. Place a universal binary in Contents/Helpers or install via Homebrew. See README."
        case .probeFailed(let message):
            "Could not read audio file: \(message)"
        case .importFailed(let message):
            "Import failed: \(message)"
        case .exportFailed(let message):
            "Export failed: \(message)"
        case .verificationFailed(let message):
            "Export verification failed: \(message)"
        case .cancelled:
            "Cancelled"
        case .ripFailed(let message):
            "CD rip failed: \(message)"
        case .noOpticalDrive:
            "No optical drive is connected. Plug in a USB SuperDrive or a generic USB DVD drive, then insert an audio CD."
        case .discDisappeared:
            "The audio CD disappeared during the rip. USB optical drives disconnect easily — check the cable and try that disc again."
        case .fileMissing(let path):
            "Missing file: \(path)"
        }
    }
}
