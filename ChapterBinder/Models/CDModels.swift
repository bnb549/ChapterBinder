#if !APP_STORE
import Foundation

enum RipQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    case paranoiaFull
    case paranoiaOverlap
    case burst

    var id: String { rawValue }

    var label: String {
        switch self {
        case .paranoiaFull: "Paranoia full"
        case .paranoiaOverlap: "Paranoia overlap"
        case .burst: "Burst (faster)"
        }
    }

    var detail: String {
        switch self {
        case .paranoiaFull: "Maximum jitter correction. Slowest, safest for scratched discs."
        case .paranoiaOverlap: "Overlap check without the full verify pass."
        case .burst: "Fast read. Use only on clean discs."
        }
    }

    var cdparanoiaFlags: [String] {
        switch self {
        case .paranoiaFull: ["--never-skip=40"]
        case .paranoiaOverlap: ["-Y", "--never-skip=20"]
        case .burst: ["-Z"]
        }
    }
}

struct CDTrackInfo: Identifiable, Hashable, Sendable {
    var number: Int
    var start: TimeInterval
    var duration: TimeInterval
    var title: String

    var id: Int { number }
}

struct CDTOC: Hashable, Sendable {
    var bsdName: String
    var discID: String?
    var tracks: [CDTrackInfo]
    var raw: String

    var trackCount: Int { tracks.count }
    var totalDuration: TimeInterval { tracks.reduce(0) { $0 + $1.duration } }
}

struct DetectedDisc: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var bsdName: String
    var volumeURL: URL?
    var isAudioCD: Bool
    var toc: CDTOC?
    var isMock: Bool

    var trackCount: Int { toc?.trackCount ?? 0 }
    var totalDuration: TimeInterval { toc?.totalDuration ?? 0 }
}

struct RipProgress: Sendable {
    var trackNumber: Int
    var trackCount: Int
    var fraction: Double
    var message: String
    var skipped: [Int]
}

enum MockTOC {
    /// 16-track, 72:14 audiobook-style disc so the UI can be developed without a drive.
    static func make(bsdName: String = "mock0") -> CDTOC {
        let durations: [TimeInterval] = [
            245, 312, 278, 401, 267, 333, 289, 256,
            348, 221, 305, 274, 198, 362, 241, 204,
        ]
        // 72:14 = 4334 seconds. Sum of the above is 4334.
        var start: TimeInterval = 0
        var tracks: [CDTrackInfo] = []
        for (i, duration) in durations.enumerated() {
            tracks.append(
                CDTrackInfo(
                    number: i + 1,
                    start: start,
                    duration: duration,
                    title: String(format: "Track %02d", i + 1)
                )
            )
            start += duration
        }
        return CDTOC(
            bsdName: bsdName,
            discID: "mock.disc.id.001",
            tracks: tracks,
            raw: "MOCK TOC 16 tracks 72:14"
        )
    }

    static var detected: DetectedDisc {
        let toc = make()
        return DetectedDisc(
            id: "mock-audio-cd",
            name: "Audio CD (mock)",
            bsdName: "mock0",
            volumeURL: nil,
            isAudioCD: true,
            toc: toc,
            isMock: true
        )
    }
}
#endif
