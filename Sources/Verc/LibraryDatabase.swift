import Foundation
import SQLite3

final class LibraryDatabase {
    private let root: URL
    private var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    init(root: URL) throws {
        self.root = root
        do {
            guard sqlite3_open_v2(root.appendingPathComponent("Library.vercdb").path, &handle,
                                 SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else { throw failure }
            sqlite3_busy_timeout(handle, 5000)
            try run("PRAGMA foreign_keys = ON")
            try run("PRAGMA synchronous = FULL")
            try run("PRAGMA journal_mode = DELETE")
        } catch {
            close()
            throw error
        }
    }

    deinit { close() }

    private func close() {
        for statement in statements.values { sqlite3_finalize(statement) }
        statements.removeAll()
        sqlite3_close(handle)
        handle = nil
    }

    private var failure: Error {
        NSError(domain: "Verc.Library", code: Int(sqlite3_errcode(handle)),
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(handle))])
    }

    @discardableResult func run(_ sql: String, _ values: [String?] = []) throws -> [[String?]] {
        let statement: OpaquePointer
        if let cached = statements[sql] { statement = cached }
        else {
            var prepared: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else { throw failure }
            statement = prepared
            statements[sql] = statement
        }
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        guard sqlite3_bind_parameter_count(statement) == values.count else { throw CocoaError(.coderInvalidValue) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result = value.map { value in
                value.utf8CString.withUnsafeBufferPointer {
                    sqlite3_bind_text(statement, index, $0.baseAddress, Int32($0.count - 1), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            } ?? sqlite3_bind_null(statement, index)
            guard result == SQLITE_OK else { throw failure }
        }
        var rows: [[String?]] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                rows.append((0..<sqlite3_column_count(statement)).map { index in
                    guard let text = sqlite3_column_text(statement, index) else { return nil }
                    return String(decoding: UnsafeBufferPointer(start: text, count: Int(sqlite3_column_bytes(statement, index))), as: UTF8.self)
                })
            case SQLITE_DONE: return rows
            default: throw failure
            }
        }
    }

    func absoluteURL(_ value: String) throws -> URL {
        guard let url = URL(string: value) else { throw CocoaError(.fileReadCorruptFile) }
        return url.scheme == nil ? URL(string: value, relativeTo: root)!.absoluteURL : url
    }

    func relativeURL(_ url: URL) -> String {
        let prefix = root.path + "/"
        guard url.isFileURL, url.path.hasPrefix(prefix) else { return url.absoluteString }
        return String(url.path.dropFirst(prefix.count)).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
    }

    func read() throws -> [FavoritePage] {
        var pages: [FavoritePage] = []
        var indexes: [String: Int] = [:]
        for row in try run("""
            SELECT id, title, directory, background, cleared_title, tmdb_id, media_type, tmdb_title,
                   overview, release_date, poster_url, backdrop_url, tmdb_url, backdrops_loaded, episodes_loaded
            FROM items ORDER BY position
            """) {
            guard let key = row[0], let id = UUID(uuidString: key), let title = row[1], let directory = row[2],
                  !directory.isEmpty, directory != ".", directory != "..", !directory.contains("/"), !directory.contains(":") else {
                throw CocoaError(.fileReadCorruptFile)
            }
            var page = FavoritePage(id: id, title: title, background: try row[3].map(absoluteURL), clearedInfoTitle: row[4], directory: directory)
            page.libraryURL = root
            if let value = row[5] {
                guard let tmdbID = Int(value), let type = row[6].flatMap(TMDBTitle.MediaType.init(rawValue:)),
                      let name = row[7], let overview = row[8], let link = row[12] else { throw CocoaError(.fileReadCorruptFile) }
                page.info = TMDBTitle(id: tmdbID, mediaType: type, title: name, overview: overview, releaseDate: row[9],
                                      posterURL: try row[10].map(absoluteURL), backgroundURL: try row[11].map(absoluteURL),
                                      backgroundURLs: row[13] == "1" ? [] : nil, url: try absoluteURL(link))
            }
            let episodes = row[14].flatMap(Int.init) ?? 0
            page.episodeTitles = episodes & 1 == 0 ? nil : [:]
            page.episodeImages = episodes & 2 == 0 ? nil : [:]
            page.cachedArtwork = [:]
            indexes[key] = pages.count
            pages.append(page)
        }
        for row in try run("SELECT item_id, url FROM media ORDER BY item_id, position") {
            guard let key = row[0], let index = indexes[key], let url = row[1] else { throw CocoaError(.fileReadCorruptFile) }
            pages[index].media.append(try absoluteURL(url))
        }
        for row in try run("SELECT item_id, url FROM backdrops ORDER BY item_id, position") {
            guard let key = row[0], let index = indexes[key], let url = row[1] else { throw CocoaError(.fileReadCorruptFile) }
            pages[index].info?.backgroundURLs?.append(try absoluteURL(url))
        }
        for row in try run("SELECT item_id, episode, title, image_url FROM episodes") {
            guard let key = row[0], let index = indexes[key], let episode = row[1] else { throw CocoaError(.fileReadCorruptFile) }
            if let title = row[2] { pages[index].episodeTitles?[episode] = title }
            if let image = row[3] { pages[index].episodeImages?[episode] = try absoluteURL(image) }
        }
        for row in try run("SELECT item_id, url, filename FROM artwork") {
            guard let key = row[0], let index = indexes[key], let url = row[1], let name = row[2] else { throw CocoaError(.fileReadCorruptFile) }
            pages[index].cachedArtwork?[url] = name
        }
        return pages
    }

    func write(_ pages: [FavoritePage]) throws {
        try run("DELETE FROM items")
        for (position, page) in pages.enumerated() {
            guard let directory = page.directory, !directory.isEmpty, directory != ".", directory != "..",
                  !directory.contains("/"), !directory.contains(":") else { throw CocoaError(.fileReadCorruptFile) }
            let id = page.id.uuidString
            let info = page.info
            let episodes = (page.episodeTitles == nil ? 0 : 1) | (page.episodeImages == nil ? 0 : 2)
            try run("""
                INSERT INTO items (id, position, title, directory, background, cleared_title, tmdb_id, media_type,
                                   tmdb_title, overview, release_date, poster_url, backdrop_url, tmdb_url, backdrops_loaded, episodes_loaded)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [id, String(position), page.title, directory, page.background.map(relativeURL), page.clearedInfoTitle,
                      info.map { String($0.id) }, info?.mediaType.rawValue, info?.title, info?.overview, info?.releaseDate,
                      info?.posterURL.map(relativeURL), info?.backgroundURL.map(relativeURL), info.map { relativeURL($0.url) },
                      info?.backgroundURLs == nil ? "0" : "1", String(episodes)])
            for (position, url) in page.media.enumerated() {
                try run("INSERT INTO media VALUES (?, ?, ?)", [id, String(position), relativeURL(url)])
            }
            for (position, url) in (info?.backgroundURLs ?? []).enumerated() {
                try run("INSERT INTO backdrops VALUES (?, ?, ?)", [id, String(position), relativeURL(url)])
            }
            for episode in Set((page.episodeTitles ?? [:]).keys).union((page.episodeImages ?? [:]).keys) {
                try run("INSERT INTO episodes VALUES (?, ?, ?, ?)", [id, episode, page.episodeTitles?[episode], page.episodeImages?[episode].map(relativeURL)])
            }
            for (url, name) in page.cachedArtwork ?? [:] {
                try run("INSERT INTO artwork VALUES (?, ?, ?)", [id, url, name])
            }
        }
    }
}
