import AVFoundation
import Foundation
import os

nonisolated struct ChapterlineReport: Sendable, Equatable {
    var av: Int
    var nero: Int
    var expected: Int
    var line: String
}

nonisolated struct MP4Scan: Sendable, Equatable {
    var majorBrand: String = ""
    var compatibleBrands: [String] = []
    var chpl: Data?
    var hasChapterReference = false
    var hasCover = false
    var stikType: UInt32?
    var stikValue: UInt32?
}

/// Pass/fail gate for a finished `.m4b`. Nero `chpl` and AVFoundation chapter groups decide success.
nonisolated enum ChapterlineVerifier {
    private static let log = Logger(subsystem: "com.benmonroe.ChapterBinder", category: "export")

    static func verify(
        url: URL,
        marks: [ChapterTimeline.Mark],
        expectedDuration: TimeInterval,
        hadCover: Bool
    ) async throws -> ChapterlineReport {
        let expected = marks.count
        let scan = (try? MP4Scan.read(url: url)) ?? MP4Scan()
        let nero = NeroChapterBox.parse(scan.chpl ?? Data(), fileDuration: expectedDuration)
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let groups = await chapterGroups(in: asset)
        let av = groups.count
        let duration = (try? await asset.load(.duration).seconds) ?? 0

        log.info(
            "export chapters av=\(av, privacy: .public) nero=\(nero.count, privacy: .public) expected=\(expected, privacy: .public) path=\(url.path, privacy: .public)"
        )
        let report = ChapterlineReport(
            av: av,
            nero: nero.count,
            expected: expected,
            line: "\(expected) chapters written (AV \(av), Nero \(nero.count))"
        )

        if scan.chpl == nil || nero.count != expected {
            throw AppError.verificationFailed(
                "moov/udta/chpl \(scan.chpl == nil ? "is missing" : "has \(nero.count) chapters, expected \(expected)"). Chapterline will not show this chapter list."
            )
        }
        for (index, mark) in marks.enumerated() {
            let title = NeroChapterBox.truncateTitle(mark.title)
            let got = nero[index]
            if got.title != title {
                throw AppError.verificationFailed(
                    "moov/udta/chpl title \(index + 1) is “\(got.title)”, expected “\(title)”."
                )
            }
            if abs(got.start - (index == 0 ? 0 : mark.start)) > 0.05 {
                throw AppError.verificationFailed(
                    "moov/udta/chpl chapter \(index + 1) starts at \(String(format: "%.3f", got.start))s, expected \(String(format: "%.3f", mark.start))s."
                )
            }
        }

        if expected >= 2 {
            let dummy = isWholeFileDummy(groups, fileDuration: duration)
            if av < 2 || dummy {
                throw AppError.verificationFailed(
                    "tref/chap QuickTime chapter track \(av == 0 ? "is missing" : "has \(av) groups"). Books will show one chapter. AVFoundation needs the audio track’s tref/chap."
                )
            }
        } else if expected == 1 && av != 1 {
            throw AppError.verificationFailed(
                "tref/chap QuickTime chapter track has \(av) groups, expected 1."
            )
        }

        if hadCover && !scan.hasCover {
            throw AppError.verificationFailed("Cover art was not embedded (moov/udta/meta/ilst/covr is missing).")
        }
        if expectedDuration > 1 {
            let low = expectedDuration * 0.95 - 1
            let high = expectedDuration * 1.05 + 1
            if duration < low || duration > high {
                throw AppError.verificationFailed(
                    "Output duration \(TimeFormatting.clock(duration)) is outside 5% of source \(TimeFormatting.clock(expectedDuration))."
                )
            }
        }
        return report
    }

    static func chapterGroups(in asset: AVURLAsset) async -> [AVTimedMetadataGroup] {
        let locales = (try? await asset.load(.availableChapterLocales)) ?? []
        var tried: [Locale] = []
        for locale in locales + [Locale(identifier: "und"), Locale(identifier: "en")] {
            if tried.contains(where: { $0.identifier == locale.identifier }) { continue }
            tried.append(locale)
        }
        if tried.isEmpty {
            tried = [Locale(identifier: "und"), Locale(identifier: "en")]
        }
        var best: [AVTimedMetadataGroup] = []
        for locale in tried {
            let groups = (try? await asset.loadChapterMetadataGroups(
                withTitleLocale: locale,
                containingItemsWithCommonKeys: [.commonKeyTitle]
            )) ?? []
            if groups.count > best.count {
                best = groups
            }
        }
        return best
    }

    private static func isWholeFileDummy(_ groups: [AVTimedMetadataGroup], fileDuration: TimeInterval) -> Bool {
        guard groups.count == 1 else { return false }
        let start = groups[0].timeRange.start.seconds
        let span = groups[0].timeRange.duration.seconds
        if start <= 1, span <= 0.5 { return true }
        if fileDuration > 0, start <= 1, start + span >= fileDuration - 1 { return true }
        return false
    }
}

nonisolated extension MP4Scan {
    static func read(url: URL) throws -> MP4Scan {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        var scan = MP4Scan()
        var offset: UInt64 = 0
        while offset + 8 <= fileSize {
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: 16), header.count >= 8 else { break }
            let size32 = readUInt32(header, 0) ?? 0
            let type = AtomCode(header[4], header[5], header[6], header[7])
            var headerLength = 8
            var size = UInt64(size32)
            if size32 == 1 {
                guard header.count >= 16 else { break }
                size = readUInt64(header, 8)
                headerLength = 16
            } else if size32 == 0 {
                size = fileSize - offset
            }
            guard size >= UInt64(headerLength), offset + size <= fileSize else { break }
            let payloadStart = offset + UInt64(headerLength)
            if type == AtomCode("ftyp") {
                let payload = try readData(handle, offset: payloadStart, count: size - UInt64(headerLength))
                if payload.count >= 4 {
                    scan.majorBrand = ascii(payload.prefix(4))
                }
                var brand = 8
                while brand + 4 <= payload.count {
                    scan.compatibleBrands.append(ascii(payload.subdata(in: brand..<(brand + 4))))
                    brand += 4
                }
            } else if type == AtomCode("moov") {
                let moov = try readData(handle, offset: payloadStart, count: size - UInt64(headerLength))
                walk(moov, container: nil, into: &scan)
            }
            offset += size
        }
        return scan
    }

    private static func walk(_ data: Data, container: AtomCode?, into scan: inout MP4Scan) {
        var offset = 0
        if container == AtomCode("meta") { offset = 4 }
        while offset + 8 <= data.count {
            let size32 = readUInt32(data, offset) ?? 0
            let type = AtomCode(data[offset + 4], data[offset + 5], data[offset + 6], data[offset + 7])
            var header = 8
            var size = Int(size32)
            if size32 == 1 {
                guard offset + 16 <= data.count else { return }
                size = Int(readUInt64(data, offset + 8))
                header = 16
            } else if size32 == 0 {
                size = data.count - offset
            }
            guard size >= header, offset + size <= data.count else { return }
            let payload = (offset + header)..<(offset + size)
            if type == AtomCode("chpl") {
                scan.chpl = data.subdata(in: payload)
            } else if type == AtomCode("chap") {
                scan.hasChapterReference = true
            } else if type == AtomCode("covr") {
                scan.hasCover = size > header
            } else if type == AtomCode("stik") {
                readStik(data.subdata(in: payload), into: &scan)
            }
            if Self.containers.contains(type) {
                walk(data.subdata(in: payload), container: type, into: &scan)
            }
            offset += size
        }
    }

    private static func readStik(_ payload: Data, into scan: inout MP4Scan) {
        guard payload.count >= 16 else { return }
        let size32 = readUInt32(payload, 0) ?? 0
        let type = AtomCode(payload[4], payload[5], payload[6], payload[7])
        guard type == AtomCode("data") else { return }
        let header = size32 == 1 ? 16 : 8
        guard payload.count >= header + 8 else { return }
        scan.stikType = readUInt32(payload, header)
        scan.stikValue = readUInt32(payload, header + 8)
    }

    private static let containers: Set<AtomCode> = [
        AtomCode("moov"), AtomCode("trak"), AtomCode("mdia"),
        AtomCode("minf"), AtomCode("stbl"), AtomCode("udta"),
        AtomCode("edts"), AtomCode("meta"), AtomCode("ilst"),
        AtomCode("tref")
    ]

    private static func readData(_ handle: FileHandle, offset: UInt64, count: UInt64) throws -> Data {
        guard count <= 64 * 1024 * 1024 else {
            throw AppError.verificationFailed("moov atom is unexpectedly large.")
        }
        try handle.seek(toOffset: offset)
        let length = Int(count)
        guard let data = try handle.read(upToCount: length), data.count == length else {
            throw AppError.verificationFailed("The file ended inside moov.")
        }
        return data
    }

    private static func ascii(_ bytes: some Sequence<UInt8>) -> String {
        String(bytes.map { character in
            (character >= 32 && character < 127) ? Character(UnicodeScalar(character)) : "?"
        })
    }
}

private nonisolated struct AtomCode: Hashable, Sendable {
    var b0, b1, b2, b3: UInt8

    init(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8, _ b3: UInt8) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.b3 = b3
    }

    init(_ ascii: String) {
        let bytes = Array(ascii.utf8)
        precondition(bytes.count == 4)
        self.init(bytes[0], bytes[1], bytes[2], bytes[3])
    }
}
