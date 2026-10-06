import Foundation

nonisolated enum HelperBinary: String, Sendable {
    case ffmpeg
    case ffprobe

    var names: [String] {
        switch self {
        case .ffmpeg: ["ffmpeg"]
        case .ffprobe: ["ffprobe"]
        }
    }

    /// Only a static binary shipped in Contents/Helpers. Homebrew is not required.
    func url() throws -> URL {
        if let found = Self.find(names: names) {
            return found
        }
        throw AppError.helperMissing(rawValue)
    }

    func optionalURL() -> URL? {
        Self.find(names: names)
    }

    static var ffmpegAvailable: Bool { HelperBinary.ffmpeg.optionalURL() != nil }
    static var ffprobeAvailable: Bool { HelperBinary.ffprobe.optionalURL() != nil }

    static func find(names: [String]) -> URL? {
        let fileManager = FileManager.default
        var candidates: [URL] = []

        if let helpers = Bundle.main.builtInPlugInsURL?.deletingLastPathComponent().appendingPathComponent("Helpers") {
            candidates.append(helpers)
        }
        if let resources = Bundle.main.resourceURL?.appendingPathComponent("Helpers") {
            candidates.append(resources)
        }
        if let exec = Bundle.main.executableURL?.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Helpers") {
            // Contents/Helpers when executable is Contents/MacOS/ChapterBinder
            candidates.append(exec)
        }
        if let contents = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers") as URL? {
            candidates.append(contents)
        }

        var seen = Set<String>()
        for folder in candidates {
            let folderPath = folder.path
            if !seen.insert(folderPath).inserted { continue }
            for name in names {
                let url = folder.appendingPathComponent(name)
                if fileManager.isExecutableFile(atPath: url.path) {
                    return url
                }
            }
        }
        return nil
    }
}
