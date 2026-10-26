import Foundation
import Synchronization

struct MediaFilename: Sendable {
    let title: String
    let year: Int?
    let season: Int?
    let episode: Int?
    var episodeKey: String? { season.flatMap { season in episode.map { Self.episodeKey(season, $0) } } }
    private static let episodePattern = try! NSRegularExpression(pattern: #"(?i)(?:^|[ ._\-\[(])S(\d{1,3})[ ._-]*E(\d{1,4})(?!\d)"#)
    private static let yearPattern = try! NSRegularExpression(pattern: #"\b(?:19|20)\d{2}\b"#)
    // Views parse filenames on every render, and each parse runs several regular expressions.
    private static let cache = Mutex<[String: MediaFilename]>([:])

    static func episodeKey(_ season: Int, _ episode: Int) -> String { "\(season):\(episode)" }

    init(_ name: String) {
        if let cached = Self.cache.withLock({ $0[name] }) { self = cached; return }
        var title = name
        let match = Self.episodePattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name))
        season = match.flatMap { Range($0.range(at: 1), in: name) }.flatMap { Int(name[$0]) }
        episode = match.flatMap { Range($0.range(at: 2), in: name) }.flatMap { Int(name[$0]) }
        if let range = match.flatMap({ Range($0.range, in: name) }) { title = String(name[..<range.lowerBound]) }
        title = title.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[._]+"#, with: " ", options: .regularExpression)
        if let range = title.range(of: #"(?i)\b(?:s\d{1,3}|season\s+\d{1,3})\b"#, options: .regularExpression) {
            title = String(title[..<range.lowerBound])
        }
        // Use the last year, so a number in the title such as "Blade Runner 2049 (2017)" stays in the title.
        if let range = Self.yearPattern.matches(in: title, range: NSRange(title.startIndex..., in: title)).compactMap({ Range($0.range, in: title) })
            .last(where: { !title[..<$0.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            year = Int(title[range])
            title = String(title[..<range.lowerBound])
        } else { year = nil }
        if let range = title.range(of: #"(?i)(?:^|\s)(?:\d{3,4}p|[48]K|BluRay|BDRip|WEB[ -]?DL|WEBRip|HDTV|[xh][ .]?26[45])\b"#, options: .regularExpression) {
            title = String(title[..<range.lowerBound])
        }
        self.title = title.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ._-()[]"))
        let parsed = self
        Self.cache.withLock { cache in
            if cache.count >= 10000 { cache.removeAll() }
            cache[name] = parsed
        }
    }
}

struct TMDBTitle: Codable, Sendable {
    enum MediaType: String, Codable, Sendable { case movie, tv }
    struct Credit: Codable, Equatable, Sendable {
        let role: String
        let names: [String]
    }
    let id: Int
    let mediaType: MediaType
    let title: String
    let overview: String
    let releaseDate: String?
    let posterURL: URL?
    let backgroundURL: URL?
    var backgroundURLs: [URL]?
    let url: URL
    var credits: [Credit]?
}

enum TMDB {
    struct Request: Encodable {
        var query: String?
        var type: String
        var id: Int?
        var season: Int?
        var credits: Bool?
    }

    struct Response: Decodable {
        var results: [TMDBTitle]?
        var episodes: [Episode]?
        var backgroundURLs: [URL]?
        var credits: [TMDBTitle.Credit]?
    }

    struct Episode: Decodable {
        let season: Int
        let episode: Int
        let title: String
        let stillURL: URL?
    }

    static func load(_ body: Request) async throws -> Response {
        var request = URLRequest(url: URL(string: "https://verc.download/tmdb")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}
