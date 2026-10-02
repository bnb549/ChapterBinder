import Foundation

/// Nero `chpl` payload (FullBox body, no box header).
///
/// Version 1, flags 0, chapter count as a big-endian UInt32 at offset 4.
/// Each entry is a big-endian start in 100-nanosecond ticks, a UInt8 UTF-8
/// length, and the title bytes. No reserved byte and no trailing NUL.
nonisolated enum NeroChapterBox {
    struct Entry: Equatable, Sendable {
        var start: TimeInterval
        var title: String
    }

    static let minimumGap: TimeInterval = 0.1
    static let maximumStart: TimeInterval = 60 * 60 * 24 * 366 * 10
    static let maxTitleBytes = 255

    static func payload(
        chapters: [(start: TimeInterval, title: String)],
        fileDuration: TimeInterval?
    ) throws -> Data {
        guard !chapters.isEmpty else {
            throw AppError.exportFailed("Refusing to write an empty Nero chpl atom.")
        }

        var entries: [(ticks: UInt64, title: Data)] = []
        entries.reserveCapacity(chapters.count)
        var writtenStart: TimeInterval = 0
        for (index, chapter) in chapters.enumerated() {
            let start = index == 0 ? 0 : chapter.start
            guard start.isFinite, start >= 0, start <= maximumStart else {
                throw AppError.exportFailed("Chapter \(index + 1) has a start time Chapterline will reject.")
            }
            if let fileDuration, fileDuration > 0, start > fileDuration + 1 {
                throw AppError.exportFailed("Chapter \(index + 1) starts after the audio ends.")
            }
            if index > 0 {
                let gap = start - writtenStart
                if gap < minimumGap {
                    throw AppError.exportFailed(
                        "Chapter \(index + 1) is only \(String(format: "%.3f", gap))s after the previous chapter. Nero starts must increase by at least 0.1 seconds."
                    )
                }
            }
            writtenStart = start
            let ticks = UInt64((start * 10_000_000).rounded())
            if let last = entries.last, ticks <= last.ticks {
                throw AppError.exportFailed("Chapter \(index + 1) does not start after the previous chapter on the Nero clock.")
            }
            let title = titleData(chapter.title, index: index)
            entries.append((ticks, title))
        }

        var data = Data()
        data.append(1) // version
        data.append(contentsOf: [0, 0, 0]) // flags
        appendUInt32(UInt32(entries.count), to: &data)
        for entry in entries {
            appendUInt64(entry.ticks, to: &data)
            data.append(UInt8(entry.title.count))
            data.append(entry.title)
        }
        return data
    }

    /// Reads the version-1 layout this app writes: count is a UInt32 at offset 4.
    static func parse(_ data: Data, fileDuration: TimeInterval? = nil) -> [Entry] {
        guard data.count >= 9, data[0] == 1 else { return [] }
        guard let declared = readUInt32(data, 4), declared > 0 else { return [] }
        var offset = 8
        var entries: [Entry] = []
        for _ in 0..<declared {
            guard offset + 9 <= data.count else { return entries }
            let ticks = readUInt64(data, offset)
            offset += 8
            let length = Int(data[offset])
            offset += 1
            guard offset + length <= data.count else { return entries }
            let titleData = data.subdata(in: offset..<(offset + length))
            offset += length
            let start = TimeInterval(ticks) / 10_000_000
            guard start.isFinite, start >= 0, start <= maximumStart else { continue }
            if let fileDuration, fileDuration > 0, start > fileDuration + 1 { continue }
            if let last = entries.last, start < last.start { continue }
            let title = String(data: titleData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            entries.append(Entry(start: start, title: title.isEmpty ? "Chapter \(entries.count + 1)" : title))
        }
        return entries
    }

    static func truncateTitle(_ title: String, maxBytes: Int = maxTitleBytes) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmed.isEmpty ? "Chapter" : trimmed
        var data = Data(source.utf8)
        if data.count <= maxBytes {
            return source
        }
        data = data.prefix(maxBytes)
        while !data.isEmpty, String(data: data, encoding: .utf8) == nil {
            data.removeLast()
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.isEmpty ? "Chapter" : text
    }

    private static func titleData(_ title: String, index: Int) -> Data {
        let text = truncateTitle(title.isEmpty ? "Chapter \(index + 1)" : title)
        var data = Data(text.utf8)
        if data.count > maxTitleBytes {
            data = data.prefix(maxTitleBytes)
            while !data.isEmpty, String(data: data, encoding: .utf8) == nil {
                data.removeLast()
            }
        }
        return data
    }
}

nonisolated func appendUInt32(_ value: UInt32, to data: inout Data) {
    var big = value.bigEndian
    withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
}

nonisolated func appendUInt64(_ value: UInt64, to data: inout Data) {
    var big = value.bigEndian
    withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
}

nonisolated func readUInt32(_ data: Data, _ offset: Int) -> UInt32? {
    guard offset >= 0, offset + 4 <= data.count else { return nil }
    let slice = data.subdata(in: offset..<(offset + 4))
    return slice.withUnsafeBytes { raw in
        UInt32(bigEndian: raw.load(as: UInt32.self))
    }
}

nonisolated func readUInt64(_ data: Data, _ offset: Int) -> UInt64 {
    guard offset >= 0, offset + 8 <= data.count else { return 0 }
    let slice = data.subdata(in: offset..<(offset + 8))
    return slice.withUnsafeBytes { raw in
        UInt64(bigEndian: raw.load(as: UInt64.self))
    }
}
