import Foundation

enum ChapterListFormat: String, CaseIterable, Identifiable, Sendable {
    case youtube
    case chaptersTxt
    case ffmetadata

    var id: String { rawValue }

    var label: String {
        switch self {
        case .youtube: "YouTube timestamps"
        case .chaptersTxt: "chapters.txt"
        case .ffmetadata: "FFmpeg ffmetadata"
        }
    }

    var filename: String {
        switch self {
        case .youtube: "chapters.txt"
        case .chaptersTxt: "chapters.txt"
        case .ffmetadata: "ffmetadata.txt"
        }
    }
}

enum ChapterListIO {
    static func parse(_ text: String) -> [EmbeddedChapter] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(";FFMETADATA") || trimmed.contains("[CHAPTER]") {
            return parseFFMetadata(trimmed)
        }
        return parseTimestampList(trimmed)
    }

    /// YouTube (`0:00 Title`) and `00:00:00 Title` / `00:00:00.000 Title`.
    static func parseTimestampList(_ text: String) -> [EmbeddedChapter] {
        let pattern = #"^\s*(?:(\d{1,2}):)?(\d{1,2}):(\d{2}(?:\.\d+)?)\s+(.+?)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
            return []
        }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var starts: [(TimeInterval, String)] = []
        for match in matches {
            let hours = match.range(at: 1).location != NSNotFound ? Double(ns.substring(with: match.range(at: 1))) ?? 0 : 0
            let minutes = Double(ns.substring(with: match.range(at: 2))) ?? 0
            let seconds = Double(ns.substring(with: match.range(at: 3))) ?? 0
            let title = ns.substring(with: match.range(at: 4))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let start = hours * 3600 + minutes * 60 + seconds
            starts.append((start, title))
        }
        starts.sort { $0.0 < $1.0 }
        var chapters: [EmbeddedChapter] = []
        for (i, item) in starts.enumerated() {
            let end = i + 1 < starts.count ? starts[i + 1].0 : item.0
            chapters.append(EmbeddedChapter(title: item.1, start: item.0, duration: max(0, end - item.0)))
        }
        return chapters
    }

    static func parseFFMetadata(_ text: String) -> [EmbeddedChapter] {
        var chapters: [EmbeddedChapter] = []
        var currentStart: TimeInterval?
        var currentEnd: TimeInterval?
        var currentTitle = ""
        var timebase: Double = 1_000

        func flush() {
            guard let start = currentStart else { return }
            let end = currentEnd ?? start
            chapters.append(EmbeddedChapter(title: currentTitle.isEmpty ? "Chapter" : currentTitle, start: start, duration: max(0, end - start)))
            currentStart = nil
            currentEnd = nil
            currentTitle = ""
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[CHAPTER]") {
                flush()
                timebase = 1_000
                continue
            }
            if line.hasPrefix("TIMEBASE=") {
                let value = String(line.dropFirst("TIMEBASE=".count))
                let parts = value.split(separator: "/")
                if parts.count == 2, let num = Double(parts[0]), let den = Double(parts[1]), den != 0 {
                    timebase = den / num
                }
                continue
            }
            if line.hasPrefix("START=") {
                if let v = Double(line.dropFirst("START=".count)) {
                    currentStart = v / timebase
                }
                continue
            }
            if line.hasPrefix("END=") {
                if let v = Double(line.dropFirst("END=".count)) {
                    currentEnd = v / timebase
                }
                continue
            }
            if line.hasPrefix("title=") {
                currentTitle = unescapeFF(String(line.dropFirst("title=".count)))
            }
        }
        flush()
        return chapters
    }

    static func parseCUE(_ text: String) -> [EmbeddedChapter] {
        var chapters: [EmbeddedChapter] = []
        var pendingTitle = "Track"
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.uppercased().hasPrefix("TITLE ") {
                pendingTitle = unquote(String(line.dropFirst(6)))
            } else if line.uppercased().hasPrefix("INDEX 01") {
                let rest = line.dropFirst(8).trimmingCharacters(in: .whitespaces)
                if let start = parseCUEIndex(rest) {
                    chapters.append(EmbeddedChapter(title: pendingTitle, start: start, duration: 0))
                }
            }
        }
        chapters.sort { $0.start < $1.start }
        for i in chapters.indices {
            let end = i + 1 < chapters.count ? chapters[i + 1].start : chapters[i].start
            chapters[i].duration = max(0, end - chapters[i].start)
        }
        return chapters
    }

    static func export(_ project: BookProject, format: ChapterListFormat) -> String {
        switch format {
        case .youtube, .chaptersTxt:
            return project.chapters.map { chapter in
                "\(TimeFormatting.clock(chapter.start)) \(chapter.title)"
            }.joined(separator: "\n") + "\n"
        case .ffmetadata:
            return FFMetadataBuilder.build(project: project, includeGlobalTags: false)
        }
    }

    static func apply(_ chapters: [EmbeddedChapter], to project: inout BookProject) {
        guard !chapters.isEmpty else { return }
        if project.tracks.count == 1, let track = project.tracks.first {
            project.chapters = chapters.map { item in
                Chapter(
                    title: item.title,
                    trackIDs: [track.id],
                    startOffset: item.start,
                    endOffset: item.duration > 0 ? item.start + item.duration : nil
                )
            }
            project.recomputeTimeline()
            return
        }
        // Snap each timestamp to the track whose start is nearest on the timeline.
        project.recomputeTimeline()
        var newChapters: [Chapter] = []
        let trackStarts: [(SourceTrack, TimeInterval)] = {
            var t: TimeInterval = 0
            var result: [(SourceTrack, TimeInterval)] = []
            for track in project.tracks {
                result.append((track, t))
                t += track.duration
            }
            return result
        }()
        for (i, item) in chapters.enumerated() {
            let end = i + 1 < chapters.count ? chapters[i + 1].start : project.totalDuration
            let contained = trackStarts.filter { start in
                start.1 + start.0.duration > item.start + 0.01 && start.1 < end - 0.01
            }
            let ids = contained.map(\.0.id)
            let firstStart = contained.first?.1 ?? item.start
            newChapters.append(
                Chapter(
                    title: item.title,
                    trackIDs: ids.isEmpty ? (project.tracks.first.map { [$0.id] } ?? []) : ids,
                    startOffset: max(0, item.start - firstStart),
                    endOffset: contained.last.map { last in
                        min(last.0.duration, end - last.1)
                    }
                )
            )
        }
        if !newChapters.isEmpty {
            project.chapters = newChapters
            project.recomputeTimeline()
        }
    }

    private static func parseCUEIndex(_ value: String) -> TimeInterval? {
        // MM:SS:FF at 75 frames/sec
        let parts = value.split(separator: ":")
        guard parts.count == 3,
              let m = Double(parts[0]),
              let s = Double(parts[1]),
              let f = Double(parts[2])
        else { return TimeFormatting.parse(value) }
        return m * 60 + s + f / 75.0
    }

    private static func unquote(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("\"") && t.hasSuffix("\"") && t.count >= 2 {
            t.removeFirst()
            t.removeLast()
        }
        return t
    }

    private static func unescapeFF(_ s: String) -> String {
        s.replacingOccurrences(of: "\\=", with: "=")
            .replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\#", with: "#")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}
