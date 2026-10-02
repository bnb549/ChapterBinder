import Foundation

/// App-scoped bookmarks beside the path strings already stored in project JSON.
/// A missing bookmark still opens. The sandboxed target asks for a relink when
/// the bookmark is stale and the path is not readable inside the container.
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
                #if APP_STORE
                if stale {
                    throw AppError.relinkRequired(path)
                }
                #endif
                if resolved.startAccessingSecurityScopedResource() {
                    return Lease(url: resolved, accessed: true)
                }
                #if APP_STORE
                throw AppError.relinkRequired(path)
                #endif
            } else {
                #if APP_STORE
                throw AppError.relinkRequired(path)
                #endif
            }
        }
        if FileManager.default.isReadableFile(atPath: pathURL.path) {
            return Lease(url: pathURL, accessed: false)
        }
        #if APP_STORE
        throw AppError.relinkRequired(path)
        #else
        throw AppError.fileMissing(path)
        #endif
    }
}
