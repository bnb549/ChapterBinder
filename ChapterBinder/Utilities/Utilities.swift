import Foundation

nonisolated enum NaturalSort {
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        a.compare(b, options: [.numeric, .caseInsensitive, .diacriticInsensitive, .widthInsensitive])
    }

    static func sorted<T>(_ items: [T], key: (T) -> String) -> [T] {
        items.sorted { compare(key($0), key($1)) == .orderedAscending }
    }
}

nonisolated enum FilenameSanitizer {
    static func filename(from title: String, ext: String) -> String {
        var name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "Untitled Book" }
        let illegal = CharacterSet(charactersIn: ":/\\?%*|\"<>")
        name = name.components(separatedBy: illegal).joined(separator: "-")
        name = name.replacingOccurrences(of: "  ", with: " ")
        while name.hasSuffix(".") { name.removeLast() }
        return "\(name).\(ext)"
    }

    static func paddedSeriesPart(_ part: String) -> String {
        let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed) else { return trimmed }
        return String(format: "%02d", value)
    }
}

nonisolated enum TimeFormatting {
    static func clock(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval >= 0 else { return "0:00" }
        let total = Int(interval.rounded(.towardZero))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    static func clockMillis(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval >= 0 else { return "0:00.000" }
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        let seconds = interval.truncatingRemainder(dividingBy: 60)
        if hours > 0 {
            return String(format: "%d:%02d:%06.3f", hours, minutes, seconds)
        }
        return String(format: "%d:%06.3f", minutes, seconds)
    }

    /// Parses `H:MM:SS`, `M:SS`, `H:MM:SS.mmm`, or a raw seconds value.
    static func parse(_ text: String) -> TimeInterval? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed.contains(":") {
            let parts = trimmed.split(separator: ":")
            guard parts.count >= 2, parts.count <= 3 else { return nil }
            let values = parts.compactMap { Double($0) }
            guard values.count == parts.count else { return nil }
            if values.count == 3 {
                return values[0] * 3600 + values[1] * 60 + values[2]
            }
            return values[0] * 60 + values[1]
        }
        return Double(trimmed)
    }
}

nonisolated enum DiscFolder {
    /// Detects "CD1", "Disc 2", "Disk 03", "CD 1" in a path component.
    static func discIndex(in path: String) -> Int? {
        let ns = path as NSString
        let pattern = "(?i)(?:^|[/\\\\ _.-])(?:cd|disc|disk)\\s*0*([0-9]{1,2})(?:$|[/\\\\ _.-])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: path, options: [], range: range),
              match.numberOfRanges > 1,
              let swiftRange = Range(match.range(at: 1), in: path)
        else { return nil }
        return Int(path[swiftRange])
    }
}

nonisolated enum AudioFileType {
    static let extensions: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "wav", "aiff", "aif", "flac", "caf", "mp4"
    ]
    static let drmExtensions: Set<String> = ["aa", "aax"]

    static func isAudio(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    static func isAudibleDRM(_ url: URL) -> Bool {
        drmExtensions.contains(url.pathExtension.lowercased())
    }
}
