import Foundation

/// Chapter starts, ends, and titles derived from probed durations.
/// No file I/O. A CD track is not a chapter; offsets shift this timeline.
nonisolated enum ChapterTimeline {
    struct Mark: Equatable, Sendable {
        var title: String
        var start: TimeInterval
        var end: TimeInterval
    }

    static func marks(for project: BookProject) throws -> [Mark] {
        guard !project.tracks.isEmpty else {
            throw AppError.exportFailed("This book has no source tracks.")
        }
        guard !project.chapters.isEmpty else {
            throw AppError.exportFailed(
                "This book has no chapters. Export will not write a one-chapter file to stand in for a missing chapter list."
            )
        }

        var copy = project
        copy.recomputeTimeline()

        var marks: [Mark] = []
        marks.reserveCapacity(copy.chapters.count)
        for (index, chapter) in copy.chapters.enumerated() {
            guard chapter.start.isFinite, chapter.duration.isFinite, chapter.duration > 0 else {
                throw AppError.exportFailed(
                    "Chapter \(index + 1) has no duration. Chapter times come from the audio duration, not the file name."
                )
            }
            let trimmed = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = trimmed.isEmpty ? "Chapter \(index + 1)" : trimmed
            marks.append(Mark(title: title, start: chapter.start, end: chapter.start + chapter.duration))
        }

        if marks[0].start > 0.001 {
            throw AppError.exportFailed("The first chapter does not start at 0.")
        }
        marks[0] = Mark(title: marks[0].title, start: 0, end: marks[0].end)

        for index in 1..<marks.count {
            let gap = marks[index].start - marks[index - 1].start
            if !gap.isFinite || gap < NeroChapterBox.minimumGap {
                throw AppError.exportFailed(
                    "Chapter \(index + 1) (“\(marks[index].title)”) starts \(String(format: "%.3f", gap))s after the previous chapter. Starts must keep at least 0.1 seconds between them. Export stopped before muxing."
                )
            }
        }

        let duration = marks[marks.count - 1].end
        for mark in marks where mark.start > duration + 1 || mark.start > NeroChapterBox.maximumStart {
            throw AppError.exportFailed("Chapter “\(mark.title)” starts outside the book.")
        }
        return marks
    }
}
