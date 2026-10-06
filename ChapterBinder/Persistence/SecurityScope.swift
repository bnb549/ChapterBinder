import Foundation

/// App-scoped bookmarks beside the path strings already stored in project JSON.
/// A missing bookmark still opens. The app asks for a relink when the bookmark
/// is stale and the path is not readable inside the sandbox.
nonisolated enum SecurityScope {
    struct Lease: Sendable {
        var url: URL
        var accessed: Bool

        func stop() {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
    }

    static func bookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func lease(bookmark: Data?, path: String) throws -> Lease {
        let pathURL = URL(fileURLWithPath: path)
        if let bookmark {
            var stale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                if stale {
                    throw AppError.relinkRequired(path)
                }
                if resolved.startAccessingSecurityScopedResource() {
                    return Lease(url: resolved, accessed: true)
                }
                throw AppError.relinkRequired(path)
            } else {
                throw AppError.relinkRequired(path)
            }
        }
        if FileManager.default.isReadableFile(atPath: pathURL.path) {
            return Lease(url: pathURL, accessed: false)
        }
        throw AppError.relinkRequired(path)
    }

    /// Write access for an export destination. A save-panel bookmark is required
    /// outside Downloads and the app container. A missing bookmark still works
    /// when the folder itself is writable.
    static func outputLease(bookmark: Data?, path: String) throws -> Lease {
        let pathURL = URL(fileURLWithPath: path)
        if let bookmark, !bookmark.isEmpty {
            var stale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ), !stale {
                if resolved.startAccessingSecurityScopedResource() {
                    return Lease(url: resolved, accessed: true)
                }
                if canWrite(resolved) {
                    return Lease(url: resolved, accessed: false)
                }
            }
        }
        if canWrite(pathURL) {
            return Lease(url: pathURL, accessed: false)
        }
        throw AppError.exportFailed("Choose the output file again so ChapterBinder can save it.")
    }

    static func canWrite(_ url: URL) -> Bool {
        let parent = url.deletingLastPathComponent()
        if FileManager.default.isWritableFile(atPath: parent.path) { return true }
        return FileManager.default.fileExists(atPath: url.path)
            && FileManager.default.isWritableFile(atPath: url.path)
    }
}
