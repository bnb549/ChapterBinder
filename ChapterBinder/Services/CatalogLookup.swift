import Foundation

struct CatalogHit: Identifiable, Sendable, Hashable {
    var id: String
    var title: String
    var author: String
    var year: Int?
    var coverURL: URL?
    var source: String
    var description: String
}

actor RateLimiter {
    private var last: Date = .distantPast
    private let interval: TimeInterval

    init(interval: TimeInterval = 1.05) {
        self.interval = interval
    }

    func wait() async {
        let gap = interval - Date().timeIntervalSince(last)
        if gap > 0 {
            try? await Task.sleep(for: .milliseconds(Int(gap * 1000)))
        }
        last = Date()
    }
}

enum CatalogLookup {
    private static let limiter = RateLimiter()
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = [
            "User-Agent": "ChapterBinder/1.0 (local audiobook binder; offline-first; +https://github.com/benmonroe/ChapterBinder)",
            "Accept": "application/json",
        ]
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    static func search(title: String, author: String) async throws -> [CatalogHit] {
        var hits: [CatalogHit] = []
        if let ol = try? await openLibrary(title: title, author: author) {
            hits.append(contentsOf: ol)
        }
        if let gb = try? await googleBooks(title: title, author: author) {
            hits.append(contentsOf: gb)
        }
        if let mb = try? await MusicBrainzService.searchReleases(title: title, author: author) {
            hits.append(contentsOf: mb)
        }
        var seen = Set<String>()
        return hits.filter { seen.insert($0.id).inserted }
    }

    static func downloadCover(from url: URL, to destination: URL) async throws {
        await limiter.wait()
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AppError.importFailed("Cover download failed.")
        }
        let tmp = destination.deletingLastPathComponent().appendingPathComponent("cover-dl.bin")
        try data.write(to: tmp, options: .atomic)
        try CoverService.processImage(at: tmp, destination: destination)
        try? FileManager.default.removeItem(at: tmp)
    }

    private static func openLibrary(title: String, author: String) async throws -> [CatalogHit] {
        await limiter.wait()
        var comps = URLComponents(string: "https://openlibrary.org/search.json")!
        comps.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "author", value: author.isEmpty ? nil : author),
            URLQueryItem(name: "limit", value: "8"),
        ]
        guard let url = comps.url else { return [] }
        let (data, _) = try await session.data(from: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let docs = root["docs"] as? [[String: Any]]
        else { return [] }
        return docs.compactMap { doc in
            guard let title = doc["title"] as? String else { return nil }
            let authors = (doc["author_name"] as? [String])?.first ?? ""
            let year = doc["first_publish_year"] as? Int
            var cover: URL?
            if let coverID = doc["cover_i"] as? Int {
                cover = URL(string: "https://covers.openlibrary.org/b/id/\(coverID)-L.jpg")
            }
            let key = doc["key"] as? String ?? title
            return CatalogHit(
                id: "ol-\(key)",
                title: title,
                author: authors,
                year: year,
                coverURL: cover,
                source: "Open Library",
                description: (doc["first_sentence"] as? [String])?.first ?? ""
            )
        }
    }

    private static func googleBooks(title: String, author: String) async throws -> [CatalogHit] {
        await limiter.wait()
        var q = "intitle:\(title)"
        if !author.isEmpty { q += " inauthor:\(author)" }
        var comps = URLComponents(string: "https://www.googleapis.com/books/v1/volumes")!
        comps.queryItems = [
            URLQueryItem(name: "q", value: q),
            URLQueryItem(name: "maxResults", value: "8"),
            URLQueryItem(name: "printType", value: "books"),
        ]
        guard let url = comps.url else { return [] }
        let (data, _) = try await session.data(from: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [[String: Any]]
        else { return [] }
        return items.compactMap { item in
            let info = item["volumeInfo"] as? [String: Any] ?? [:]
            guard let title = info["title"] as? String else { return nil }
            let authors = (info["authors"] as? [String])?.joined(separator: ", ") ?? ""
            let year = (info["publishedDate"] as? String).flatMap { Int($0.prefix(4)) }
            var cover: URL?
            if let links = info["imageLinks"] as? [String: Any] {
                let thumb = (links["large"] as? String) ?? (links["thumbnail"] as? String)
                if let thumb {
                    cover = URL(string: thumb.replacingOccurrences(of: "http://", with: "https://"))
                }
            }
            let id = item["id"] as? String ?? title
            return CatalogHit(
                id: "gb-\(id)",
                title: title,
                author: authors,
                year: year,
                coverURL: cover,
                source: "Google Books",
                description: (info["description"] as? String) ?? ""
            )
        }
    }
}
