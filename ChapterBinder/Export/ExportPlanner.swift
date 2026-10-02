import Foundation

struct AudioSlice: Sendable, Equatable {
    var trackID: SourceTrack.ID
    var start: TimeInterval
    var end: TimeInterval
}

/// Splits a book into export volumes and decides when AAC can be copied.
nonisolated enum ExportPlanner {
    static func canStreamCopy(project: BookProject, settings: EncodeSettings) -> Bool {
        if project.loudnessNormalize || project.stripSilence { return false }
        guard project.tracks.allSatisfy(\.isAAC) else { return false }
        guard slices(for: project).allSatisfy({ $0.start <= 0.001 && nearlyFull($0, project: project) }) else {
            return false
        }
        if settings.keepSource { return true }
        return project.tracks.allSatisfy { track in
            (settings.channels == 0 || track.channels == settings.channels)
                && (settings.sampleRate == 0 || track.sampleRate == settings.sampleRate)
        }
    }

    static func slices(for project: BookProject) -> [AudioSlice] {
        var result: [AudioSlice] = []
        for chapter in project.chapters {
            let ids = chapter.trackIDs
            for (index, id) in ids.enumerated() {
                guard let track = project.track(id: id) else { continue }
                let from = index == 0 ? max(0, chapter.startOffset) : 0
                let rawEnd = index == ids.count - 1 ? (chapter.endOffset ?? track.duration) : track.duration
                let end = min(max(from, rawEnd), track.duration)
                if end - from > 0.001 {
                    result.append(AudioSlice(trackID: id, start: from, end: end))
                }
            }
        }
        return result
    }

    static func volumes(for project: BookProject) -> [BookProject] {
        let maxBytes = project.splitMaxBytes ?? 0
        let maxSeconds = (project.splitMaxHours ?? 0) * 3600
        if maxBytes <= 0 && maxSeconds <= 0 { return [project] }
        if project.chapters.isEmpty { return [project] }

        let bitrate = max(project.encodeSettings.bitrateKbps, 64)
        func estimatedBytes(_ duration: TimeInterval) -> Int64 {
            Int64(duration * Double(bitrate) * 1000 / 8)
        }

        var volumes: [BookProject] = []
        var batch: [Chapter] = []
        var accTime: TimeInterval = 0
        var accBytes: Int64 = 0

        func flush() {
            guard !batch.isEmpty else { return }
            let part = volumes.count + 1
            var copy = projectContaining(chapters: batch, in: project)
            copy.title = volumes.isEmpty && batch.count == project.chapters.count
                ? project.displayTitle
                : "\(project.displayTitle) – Part \(part)"
            copy.recomputeTimeline()
            volumes.append(copy)
            batch = []
            accTime = 0
            accBytes = 0
        }

        for chapter in project.chapters {
            let nextTime = accTime + chapter.duration
            let nextBytes = accBytes + estimatedBytes(chapter.duration)
            let overTime = maxSeconds > 0 && accTime > 0 && nextTime > maxSeconds
            let overBytes = maxBytes > 0 && accBytes > 0 && nextBytes > maxBytes
            if overTime || overBytes {
                flush()
            }
            batch.append(chapter)
            accTime += chapter.duration
            accBytes += estimatedBytes(chapter.duration)
        }
        flush()
        if volumes.count == 1 {
            var only = volumes[0]
            only.title = project.displayTitle
            only.recomputeTimeline()
            return [only]
        }
        return volumes.isEmpty ? [project] : volumes
    }

    static func volumeURL(base: URL, index: Int, count: Int) -> URL {
        if count <= 1 { return base }
        let name = base.deletingPathExtension().lastPathComponent
        let ext = base.pathExtension.isEmpty ? "m4b" : base.pathExtension
        return base.deletingLastPathComponent()
            .appendingPathComponent("\(name) - Part \(index + 1).\(ext)")
    }

    static func tempDirectory(near destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(".__chapterbinder_\(UUID().uuidString)", isDirectory: true)
    }

    static func projectContaining(chapters: [Chapter], in project: BookProject) -> BookProject {
        var copy = project
        copy.chapters = chapters
        var seen = Set<SourceTrack.ID>()
        var tracks: [SourceTrack] = []
        for chapter in chapters {
            for id in chapter.trackIDs where seen.insert(id).inserted {
                if let track = project.track(id: id) {
                    tracks.append(track)
                }
            }
        }
        copy.tracks = tracks
        copy.recomputeTimeline()
        return copy
    }

    private static func nearlyFull(_ slice: AudioSlice, project: BookProject) -> Bool {
        guard let track = project.track(id: slice.trackID) else { return false }
        return slice.end >= track.duration - 0.05
    }
}
