import Foundation

nonisolated enum NameCleanup {
    static func smart(_ raw: String) -> String {
        var s = raw
        s = stripExtension(s)
        let patterns = [
            #"^\s*\d{1,3}\s*[-._)]\s*"#,
            #"^\s*track\s*\d{1,3}\s*[-._:]?\s*"#,
            #"^\s*(?:cd|disc|disk)\s*\d{1,2}\s*[-._:]?\s*"#,
            #"^\s*\(\s*\d{1,3}\s*\)\s*"#,
            #"^\s*\[(?:cd|disc|disk)\s*\d{1,2}\]\s*"#,
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
            }
        }
        s = s.replacingOccurrences(of: "_", with: " ")
        s = s.replacingOccurrences(of: "  ", with: " ")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Normalizes "Chapter 1", "Chapter 01", "Ch. 1", "Ch 1" to "Chapter 1".
    static func normalizeChapter(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^(?i)\s*(?:chapter|ch\.?|chap\.?)\s*0*(\d+)\s*([:.\-]?\s*.*)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let numRange = Range(match.range(at: 1), in: s)
        else { return s }
        let number = Int(s[numRange]) ?? 0
        var rest = ""
        if match.numberOfRanges > 2, let restRange = Range(match.range(at: 2), in: s) {
            rest = String(s[restRange])
            rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: ":-. "))
            if !rest.isEmpty { rest = " – \(rest)" }
        }
        return "Chapter \(number)\(rest)"
    }

    static func regexReplace(_ raw: String, pattern: String, replacement: String) throws -> String {
        let regex = try NSRegularExpression(pattern: pattern, options: [])
        let range = NSRange(raw.startIndex..., in: raw)
        return regex.stringByReplacingMatches(in: raw, range: range, withTemplate: replacement)
    }

    static func stripExtension(_ name: String) -> String {
        let url = URL(fileURLWithPath: name)
        if AudioFileType.extensions.contains(url.pathExtension.lowercased()) {
            return url.deletingPathExtension().lastPathComponent
        }
        return name
    }
}
