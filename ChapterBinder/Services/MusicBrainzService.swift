import Foundation

enum MusicBrainzService {
    private static let limiter = RateLimiter()
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = [
            "User-Agent": "ChapterBinder/1.0 ( https://github.com/benmonroe/ChapterBinder )",
            "Accept": "application/json",
        ]
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    static func searchReleases(title: String, author: String) async throws -> [CatalogHit] {
        await limiter.wait()
        var query = "release:\(escape(title))"
        if !author.isEmpty {
            query += " AND artist:\(escape(author))"
        }
        var comps = URLComponents(string: "https://musicbrainz.org/ws/2/release/")!
        comps.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "8"),
        ]
        guard let url = comps.url else { return [] }
        let (data, _) = try await session.data(from: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let releases = root["releases"] as? [[String: Any]]
        else { return [] }

        return releases.compactMap { rel in
            guard let id = rel["id"] as? String, let title = rel["title"] as? String else { return nil }
            let artist = ((rel["artist-credit"] as? [[String: Any]])?.first?["name"] as? String) ?? ""
            let date = rel["date"] as? String
            let year = date.flatMap { Int($0.prefix(4)) }
            let cover = URL(string: "https://coverartarchive.org/release/\(id)/front-500")
            return CatalogHit(
                id: "mb-\(id)",
                title: title,
                author: artist,
                year: year,
                coverURL: cover,
                source: "MusicBrainz",
                description: (rel["disambiguation"] as? String) ?? ""
            )
        }
    }

    private static func escape(_ value: String) -> String {
        let special = CharacterSet(charactersIn: #"+\-&|!(){}[]^"~*?:\\"#)
        return value.unicodeScalars.map { special.contains($0) ? "\\\($0)" : String($0) }.joined()
    }
}
