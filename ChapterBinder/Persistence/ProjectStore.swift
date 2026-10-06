import Foundation

/// JSON project store under Application Support. Audio originals stay put.
/// Covers are stored beside the project file.
struct ProjectStore: Sendable {
    let root: URL
    let projectsDir: URL
    let cacheDir: URL
    let catalogCacheDir: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        root = base.appendingPathComponent("ChapterBinder", isDirectory: true)
        projectsDir = root.appendingPathComponent("Projects", isDirectory: true)
        cacheDir = root.appendingPathComponent("Cache", isDirectory: true)
        catalogCacheDir = root.appendingPathComponent("CatalogCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: catalogCacheDir, withIntermediateDirectories: true)
    }

    func projectURL(_ id: UUID) -> URL {
        projectsDir.appendingPathComponent("\(id.uuidString).chapterbinder")
    }

    func coverURL(for id: UUID) -> URL {
        projectsDir.appendingPathComponent("\(id.uuidString)-cover.jpg")
    }

    func loadAll() -> [BookProject] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil) else {
            return []
        }
        let files = items.filter { $0.pathExtension == "chapterbinder" }
        var projects: [BookProject] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for file in files {
            do {
                let data = try Data(contentsOf: file)
                projects.append(try decoder.decode(BookProject.self, from: data))
            } catch {
                continue
            }
        }
        return projects.sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(_ project: BookProject) throws {
        var copy = project
        copy.updatedAt = .now
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(copy)
        try data.write(to: projectURL(copy.id), options: .atomic)
    }

    func delete(_ id: UUID) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: projectURL(id))
        try? fm.removeItem(at: coverURL(for: id))
        try? fm.removeItem(at: cacheDir.appendingPathComponent(id.uuidString, isDirectory: true))
    }

    func clearRipCache(for id: UUID) {
        try? FileManager.default.removeItem(at: cacheDir.appendingPathComponent(id.uuidString, isDirectory: true))
    }
}
