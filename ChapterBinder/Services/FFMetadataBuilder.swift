import Foundation

enum FFMetadataBuilder {
    static func build(project: BookProject, includeGlobalTags: Bool = true) -> String {
        var lines: [String] = [";FFMETADATA1"]
        if includeGlobalTags {
            let part = FilenameSanitizer.paddedSeriesPart(project.seriesPart)
            let sortTitle = project.sortTitle.isEmpty
                ? sortName(title: project.title, series: project.series, part: part)
                : project.sortTitle

            add(&lines, "title", project.displayTitle)
            add(&lines, "artist", project.author)
            add(&lines, "album_artist", project.author)
            add(&lines, "album", project.displayTitle)
            add(&lines, "composer", project.narrator)
            add(&lines, "genre", project.genre.isEmpty ? "Audiobook" : project.genre)
            add(&lines, "comment", project.comment)
            add(&lines, "description", project.description)
            add(&lines, "synopsis", project.description)
            add(&lines, "publisher", project.publisher)
            add(&lines, "copyright", project.copyright)
            add(&lines, "language", project.language)
            if let year = project.year {
                add(&lines, "date", String(year))
                add(&lines, "year", String(year))
            }
            add(&lines, "sort_name", sortTitle)
            add(&lines, "sort_album", sortTitle)
            add(&lines, "title-sort", sortTitle)
            add(&lines, "album-sort", sortTitle)
            add(&lines, "media_type", "2") // iTunes stik = Audiobook
            if !project.series.isEmpty {
                add(&lines, "series", project.series)
                add(&lines, "show", project.series)
                add(&lines, "tvsh", project.series)
                add(&lines, "SERIES", project.series)
            }
            if !part.isEmpty {
                add(&lines, "series-part", part)
                add(&lines, "SERIES-PART", part)
                add(&lines, "track", part)
            }
            if !project.narrator.isEmpty {
                add(&lines, "NARRATOR", project.narrator)
            }
        }

        let chapters = project.chapters
        for (index, chapter) in chapters.enumerated() {
            let startMs = millis(chapter.start)
            let endMs: Int
            if index + 1 < chapters.count {
                endMs = millis(chapters[index + 1].start)
            } else {
                endMs = millis(project.totalDuration)
            }
            lines.append("[CHAPTER]")
            lines.append("TIMEBASE=1/1000")
            lines.append("START=\(startMs)")
            lines.append("END=\(max(startMs + 1, endMs))")
            add(&lines, "title", chapter.title)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func millis(_ time: TimeInterval) -> Int {
        Int((time * 1000).rounded(.towardZero))
    }

    static func escape(_ value: String) -> String {
        var s = ""
        for ch in value {
            switch ch {
            case "\\", "=", ";", "#":
                s.append("\\")
                s.append(ch)
            case "\n":
                s.append("\\\n")
            default:
                s.append(ch)
            }
        }
        return s
    }

    private static func add(_ lines: inout [String], _ key: String, _ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lines.append("\(key)=\(escape(trimmed))")
    }

    private static func sortName(title: String, series: String, part: String) -> String {
        if series.isEmpty { return title }
        if part.isEmpty { return "\(series) - \(title)" }
        return "\(series) \(part) - \(title)"
    }
}
