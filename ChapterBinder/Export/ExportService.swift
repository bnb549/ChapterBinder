import Foundation

nonisolated struct ExportProgress: Sendable {
    var fraction: Double
    var message: String
}

nonisolated struct ExportReport: Sendable, Equatable {
    var urls: [URL]
    var lines: [String]

    var message: String { lines.joined(separator: " ") }
}

/// Encodes and stamps on this Mac. Loudness filters and files the built-in encoder cannot read fail here.
nonisolated enum ExportService {
    static func export(
        project: BookProject,
        destination: URL,
        onProgress: @escaping @Sendable (ExportProgress) -> Void
    ) async throws -> ExportReport {
        try Task.checkCancellation()
        guard !project.tracks.isEmpty else {
            throw AppError.exportFailed("This book has no source tracks.")
        }
        _ = try ChapterTimeline.marks(for: project)

        let (resolved, leases) = try resolve(project)
        defer { leases.forEach { $0.stop() } }

        var cover: Data?
        if let path = resolved.coverPath {
            let lease = try SecurityScope.lease(bookmark: resolved.coverBookmark, path: path)
            defer { lease.stop() }
            cover = try Data(contentsOf: lease.url)
        }

        let volumes = ExportPlanner.volumes(for: resolved)
        let parent = destination.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        var urls: [URL] = []
        var lines: [String] = []
        for (index, volume) in volumes.enumerated() {
            try Task.checkCancellation()
            let url = ExportPlanner.volumeURL(base: destination, index: index, count: volumes.count)
            let working = ExportPlanner.tempDirectory(near: url)
            try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
            var discardWorking = false
            defer {
                if discardWorking || Task.isCancelled {
                    try? FileManager.default.removeItem(at: working)
                }
            }
            onProgress(ExportProgress(
                fraction: Double(index) / Double(volumes.count),
                message: volumes.count > 1 ? "Part \(index + 1) of \(volumes.count)" : "Exporting"
            ))
            let report: ChapterlineReport
            do {
                report = try await NativeExportService.exportVolume(
                    project: volume,
                    destination: url,
                    workingDirectory: working,
                    cover: cover,
                    onProgress: { progress in
                        let base = Double(index) / Double(volumes.count)
                        let span = 1.0 / Double(volumes.count)
                        onProgress(ExportProgress(fraction: base + progress.fraction * span, message: progress.message))
                    }
                )
            } catch let needs as ExportNeedsHelper {
                try? FileManager.default.removeItem(at: url)
                throw storeError(needs)
            }
            let line = volumes.count > 1 ? "Part \(index + 1): \(report.line)" : report.line
            lines.append(line)
            urls.append(url)
            discardWorking = true
        }
        onProgress(ExportProgress(fraction: 1, message: lines.joined(separator: " ")))
        return ExportReport(urls: urls, lines: lines)
    }

    private static func resolve(_ project: BookProject) throws -> (BookProject, [SecurityScope.Lease]) {
        var copy = project
        var leases: [SecurityScope.Lease] = []
        for index in copy.tracks.indices {
            let track = copy.tracks[index]
            let lease = try SecurityScope.lease(bookmark: track.bookmark, path: track.path)
            leases.append(lease)
            copy.tracks[index].path = lease.url.path
        }
        if let cover = copy.coverPath {
            copy.coverPath = cover
        }
        return (copy, leases)
    }

    private static func storeError(_ needs: ExportNeedsHelper) -> Error {
        switch needs {
        case .filters:
            return AppError.exportFailed(
                "Loudness normalize and silence trimming are not available in this build. Turn them off and export again. Audio is encoded on this Mac."
            )
        case .unreadable(let detail):
            return AppError.exportFailed(
                "This audio could not be encoded with the built-in encoder (\(detail)). Use AAC, MP3, or WAV."
            )
        }
    }
}
