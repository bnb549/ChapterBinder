import Foundation

nonisolated struct ExportReport: Sendable, Equatable {
    var urls: [URL]
    var lines: [String]

    var message: String { lines.joined(separator: " ") }
}

/// Native stamp on every target. ffmpeg runs only as a Developer ID encode fallback.
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
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

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
                #if APP_STORE
                try? FileManager.default.removeItem(at: url)
                throw storeError(needs)
                #else
                guard HelperBinary.ffmpeg.optionalURL() != nil else {
                    try? FileManager.default.removeItem(at: url)
                    throw storeError(needs)
                }
                report = try await FFmpegExportService.exportVolume(
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
                #endif
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
            #if APP_STORE
            return AppError.exportFailed(
                "Loudness normalize and silence trimming are not available in the App Store build. Turn them off and export again. Audio is encoded on this Mac."
            )
            #else
            return AppError.exportFailed(
                "Loudness normalize needs the optional ffmpeg helper in Contents/Helpers. Turn the option off to export with the built-in encoder, or add a static ffmpeg binary. Homebrew is not required."
            )
            #endif
        case .unreadable(let detail):
            #if APP_STORE
            return AppError.exportFailed(
                "This audio could not be encoded with the built-in encoder (\(detail)). The App Store build does not include ffmpeg."
            )
            #else
            return AppError.exportFailed(
                "This audio could not be encoded with the built-in encoder (\(detail)). Add a static ffmpeg in Contents/Helpers, or use AAC, MP3, or WAV. Homebrew is not required."
            )
            #endif
        }
    }
}
