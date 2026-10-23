import CryptoKit
import Foundation
import ImageIO

enum Library {
    static let url = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Verc Library.verclibrary", isDirectory: true)

    static func filename(_ title: String) -> String {
        let name = title.components(separatedBy: CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/:")))
            .joined(separator: "-").trimmingCharacters(in: CharacterSet(charactersIn: " .\t\n"))
        return name.isEmpty ? "Untitled" : String(name.prefix(120))
    }

    static func artworkName(_ url: URL) -> String {
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return url.pathExtension.isEmpty ? hash : hash + "." + url.pathExtension.lowercased()
    }

    // Imports leave symlinks at the original paths. Use the library file, so progress and subtitles match.
    static func resolve(_ url: URL) -> URL {
        guard url.isFileURL else { return url }
        let resolved = url.resolvingSymlinksInPath()
        return resolved.path.hasPrefix(Self.url.resolvingSymlinksInPath().path + "/") ? resolved : url
    }
}

actor LibraryStore {
    private struct Move: Codable {
        let source: URL
        let destination: URL
        let media: URL
    }

    private let root: URL
    private var connection: LibraryDatabase?

    init(url: URL = Library.url) { root = url }

    private func database() throws -> LibraryDatabase {
        let files = FileManager.default
        // Reopen when the package is deleted while Verc runs.
        if let connection, files.fileExists(atPath: root.appendingPathComponent("Library.vercdb").path) { return connection }
        connection = nil
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        try? files.setAttributes([.extensionHidden: true], ofItemAtPath: root.path)
        let database = try LibraryDatabase(root: root)
        let legacy = root.appendingPathComponent("Library.plist")
        let journal = root.appendingPathComponent(".Import.plist")
        try database.run("BEGIN IMMEDIATE")
        do {
            let version = try database.run("PRAGMA user_version").first?.first ?? nil
            guard version == "0" || version == "1" || version == "2" || version == "3" else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "This library requires a newer version of Verc."])
            }
            if version == "0" {
                try database.run("""
                    CREATE TABLE items (
                        id TEXT PRIMARY KEY, position INTEGER NOT NULL UNIQUE, title TEXT NOT NULL, directory TEXT NOT NULL,
                        background TEXT, cleared_title TEXT, tmdb_id INTEGER, media_type TEXT, tmdb_title TEXT, overview TEXT,
                        release_date TEXT, poster_url TEXT, backdrop_url TEXT, tmdb_url TEXT,
                        backdrops_loaded INTEGER NOT NULL, episodes_loaded INTEGER NOT NULL
                    )
                    """)
                for table in ["media", "backdrops"] {
                    try database.run("""
                        CREATE TABLE \(table) (item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
                                              position INTEGER NOT NULL, url TEXT NOT NULL, PRIMARY KEY (item_id, position))
                        """)
                }
                try database.run("""
                    CREATE TABLE episodes (item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
                                           episode TEXT NOT NULL, title TEXT, image_url TEXT, PRIMARY KEY (item_id, episode))
                    """)
                try database.run("""
                    CREATE TABLE artwork (item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
                                          url TEXT NOT NULL, filename TEXT NOT NULL, PRIMARY KEY (item_id, url))
                    """)
                try database.run("CREATE TABLE imports (position INTEGER PRIMARY KEY, source TEXT NOT NULL, destination TEXT NOT NULL)")
                var pages: [FavoritePage] = []
                if files.fileExists(atPath: legacy.path) {
                    pages = try PropertyListDecoder().decode([FavoritePage].self, from: Data(contentsOf: legacy))
                    for index in pages.indices {
                        pages[index].media = try pages[index].media.map { try database.absoluteURL($0.relativeString) }
                        pages[index].background = try pages[index].background.map { try database.absoluteURL($0.relativeString) }
                    }
                }
                try database.write(pages)
            } else if version == "1" {
                try database.run("ALTER TABLE pages RENAME TO items")
                for table in ["media", "backdrops", "episodes", "artwork"] {
                    try database.run("ALTER TABLE \(table) RENAME COLUMN page_id TO item_id")
                }
            }
            if version != "3" {
                // Imported files keep their original paths, so removing an item can move them back.
                try database.run("CREATE TABLE origins (destination TEXT PRIMARY KEY, source TEXT NOT NULL, media TEXT NOT NULL)")
                try database.run("PRAGMA user_version = 3")
            }
            if files.fileExists(atPath: journal.path) {
                let committed = Set(try database.read().flatMap(\.media))
                for move in try PropertyListDecoder().decode([Move].self, from: Data(contentsOf: journal)) where !committed.contains(move.media) {
                    try database.run("INSERT INTO imports (source, destination) VALUES (?, ?)", [move.source.absoluteString, database.relativeURL(move.destination)])
                }
            }
            try database.run("COMMIT")
        } catch {
            _ = try? database.run("ROLLBACK")
            throw error
        }
        if files.fileExists(atPath: journal.path) { try files.removeItem(at: journal) }
        if files.fileExists(atPath: legacy.path) {
            for page in try database.read() {
                let metadata = root.appendingPathComponent(page.directory!, isDirectory: true).appendingPathComponent("tmdb.plist")
                if files.fileExists(atPath: metadata.path) { try files.removeItem(at: metadata) }
            }
            try files.removeItem(at: legacy)
        }
        connection = database
        return database
    }

    func load() throws -> [FavoritePage] {
        let database = try database()
        recover(database)
        var pages = try database.read()
        for index in pages.indices { pages[index].cachedArtwork = localArtwork(pages[index]) }
        // Earlier versions saved favorites in UserDefaults. Their files stay where they are.
        if let data = UserDefaults.standard.data(forKey: "favoritePages") {
            var seen = Set(pages.flatMap(\.media).map(\.standardizedFileURL))
            for var page in (try? JSONDecoder().decode([FavoritePage].self, from: data)) ?? [] where !pages.contains(where: { $0.id == page.id }) {
                page.media = page.media.map(Library.resolve).filter { seen.insert($0.standardizedFileURL).inserted }
                if !page.media.isEmpty { pages.append(page) }
            }
        }
        pages = try save(pages)
        UserDefaults.standard.removeObject(forKey: "favoritePages")
        return pages
    }

    func save(_ input: [FavoritePage], importing: Set<UUID> = []) throws -> [FavoritePage] {
        let files = FileManager.default
        let database = try database()
        var pages = input
        var moves: [Move] = []
        var reserved = Set<String>()
        var movedSubtitles = Set<URL>()
        for index in pages.indices {
            if let directory = pages[index].directory {
                guard !directory.isEmpty, directory != ".", directory != "..", !directory.contains("/"),
                      !directory.contains(":") else { throw CocoaError(.fileReadCorruptFile) }
                guard importing.contains(pages[index].id) else { continue }
            } else {
                let name = Library.filename(pages[index].title)
                var directory = name
                var suffix = 2
                while files.fileExists(atPath: root.appendingPathComponent(directory).path) {
                    directory = "\(name) (\(suffix))"
                    suffix += 1
                }
                pages[index].directory = directory
            }
            let folder = root.appendingPathComponent(pages[index].directory!, isDirectory: true)
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            guard folder.resolvingSymlinksInPath().deletingLastPathComponent() == root.resolvingSymlinksInPath() else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            if importing.contains(pages[index].id) {
                for (offset, source) in pages[index].media.enumerated() {
                    guard source.isFileURL else { continue }
                    if source.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/") { continue }
                    guard try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                        throw CocoaError(.fileReadUnsupportedScheme)
                    }
                    var destination = folder.appendingPathComponent(source.lastPathComponent)
                    var suffix = 2
                    while files.fileExists(atPath: destination.path) || reserved.contains(destination.path.lowercased()) {
                        destination = folder.appendingPathComponent("\(source.lastPathComponent) (\(suffix))", isDirectory: true)
                            .appendingPathComponent(source.lastPathComponent)
                        suffix += 1
                    }
                    reserved.insert(destination.path.lowercased())
                    moves.append(Move(source: source, destination: destination, media: destination))
                    pages[index].media[offset] = destination
                    let sourceFolder = source.deletingLastPathComponent().resolvingSymlinksInPath()
                    let subtitles = destination.deletingLastPathComponent().appendingPathComponent("Subs", isDirectory: true)
                        .appendingPathComponent(destination.lastPathComponent, isDirectory: true)
                    for subtitle in MediaItem.subtitleFiles(for: source)
                    where (try? subtitle.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true && movedSubtitles.insert(subtitle).inserted {
                        let url = subtitles.appendingPathComponent(String(subtitle.path.dropFirst(sourceFolder.path.count + 1)))
                        guard !files.fileExists(atPath: url.path), reserved.insert(url.path.lowercased()).inserted else {
                            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path])
                        }
                        moves.append(Move(source: subtitle, destination: url, media: destination))
                    }
                }
                if let background = pages[index].background, background.isFileURL,
                   background.deletingLastPathComponent() != folder.appendingPathComponent("Artwork", isDirectory: true) {
                    let artwork = folder.appendingPathComponent("Artwork", isDirectory: true)
                    try files.createDirectory(at: artwork, withIntermediateDirectories: true)
                    let destination = artwork.appendingPathComponent(Library.artworkName(background))
                    if !files.fileExists(atPath: destination.path) { try files.copyItem(at: background, to: destination) }
                    pages[index].background = destination
                }
            }
            pages[index].cachedArtwork = localArtwork(pages[index])
        }
        // Commit the move list before touching files, so an interrupted import can restore its source files.
        var journal: String?
        if !moves.isEmpty {
            let prefix = root.resolvingSymlinksInPath().path + "/"
            for move in moves {
                let parent = move.destination.deletingLastPathComponent()
                guard parent.resolvingSymlinksInPath().path.hasPrefix(prefix) else { throw CocoaError(.fileReadInvalidFileName) }
                try files.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            try database.run("BEGIN IMMEDIATE")
            do {
                journal = try database.run("SELECT COALESCE(MAX(position), 0) FROM imports").first?.first ?? nil
                for move in moves {
                    try database.run("INSERT INTO imports (source, destination) VALUES (?, ?)", [move.source.absoluteString, database.relativeURL(move.destination)])
                }
                try database.run("COMMIT")
            } catch {
                _ = try? database.run("ROLLBACK")
                throw error
            }
        }
        do {
            try database.run("BEGIN IMMEDIATE")
            for move in moves {
                try files.moveItem(at: move.source, to: move.destination)
                try files.createSymbolicLink(at: move.source, withDestinationURL: move.destination)
                try database.run("INSERT OR REPLACE INTO origins VALUES (?, ?, ?)",
                                 [database.relativeURL(move.destination), move.source.absoluteString, database.relativeURL(move.media)])
            }
            try database.write(pages)
            if let journal { try database.run("DELETE FROM imports WHERE position > ?", [journal]) }
            try database.run("COMMIT")
        } catch {
            _ = try? database.run("ROLLBACK")
            recover(database)
            throw error
        }
        recover(database)
        return pages
    }

    // Moves files of interrupted imports and removed media back. A failed move stays recorded and runs again later.
    private func recover(_ database: LibraryDatabase) {
        let files = FileManager.default
        for row in (try? database.run("SELECT position, source, destination FROM imports ORDER BY position DESC")) ?? [] {
            guard let source = row[1].flatMap(URL.init(string:)), let destination = try? row[2].map(database.absoluteURL),
                  (try? restore(source, from: destination, copy: true)) != nil else { continue }
            _ = try? database.run("DELETE FROM imports WHERE position = ?", [row[0]])
        }
        for row in (try? database.run("SELECT destination, source FROM origins WHERE media NOT IN (SELECT url FROM media)")) ?? [] {
            guard let destination = try? row[0].map(database.absoluteURL), let source = row[1].flatMap(URL.init(string:)),
                  (try? restore(source, from: destination, copy: false)) != nil else { continue }
            _ = try? database.run("DELETE FROM origins WHERE destination = ?", [row[0]])
        }
        // Delete folders of removed items. Keep a folder that still holds anything except cached artwork.
        let used = Set(((try? database.run("SELECT directory FROM items")) ?? []).compactMap { $0[0] })
        for name in (try? files.contentsOfDirectory(atPath: root.path)) ?? [] where !name.hasPrefix(".") && !used.contains(name) {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  (try? files.contentsOfDirectory(atPath: folder.path))?.allSatisfy({ $0.hasPrefix(".") || $0 == "Artwork" }) == true else { continue }
            try? files.removeItem(at: folder)
        }
    }

    private func restore(_ source: URL, from destination: URL, copy: Bool) throws {
        let files = FileManager.default
        guard files.fileExists(atPath: destination.path) else { return }
        if (try? files.destinationOfSymbolicLink(atPath: source.path)) == destination.path { try files.removeItem(at: source) }
        if !files.fileExists(atPath: source.path) {
            try files.moveItem(at: destination, to: source)
        } else if copy {
            // A move does not change its source until it completes, so this destination is a partial or extra copy.
            try files.removeItem(at: destination)
        } else { throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: source.path]) }
        var folder = destination.deletingLastPathComponent()
        while folder.deletingLastPathComponent().path.hasPrefix(root.path + "/"),
              (try? files.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
            try? files.removeItem(at: folder)
            folder = folder.deletingLastPathComponent()
        }
    }

    private func localArtwork(_ page: FavoritePage) -> [String: String] {
        guard let directory = page.directory else { return [:] }
        let folder = root.appendingPathComponent(directory, isDirectory: true).appendingPathComponent("Artwork", isDirectory: true)
        let files = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        var cached: [String: String] = [:]
        for url in page.artworkURLs {
            let name = Library.artworkName(url)
            let candidates = [name, page.cachedArtwork?[url.absoluteString], (name as NSString).deletingPathExtension].compactMap { $0 }
            if let existing = candidates.first(where: files.contains) { cached[url.absoluteString] = existing }
        }
        return cached
    }

    func cacheArtwork(_ page: FavoritePage) async -> [String: String] {
        guard let directory = page.directory else { return [:] }
        let folder = root.appendingPathComponent(directory, isDirectory: true).appendingPathComponent("Artwork", isDirectory: true)
        var cached = localArtwork(page)
        let urls = page.artworkURLs.filter { cached[$0.absoluteString] == nil }
        guard !urls.isEmpty else { return cached }
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch { return cached }
        await withTaskGroup(of: (String, String)?.self) { group in
            var pending = urls.makeIterator()
            for _ in 0..<min(4, urls.count) {
                if let url = pending.next() { group.addTask { await Self.download(url, into: folder) } }
            }
            for await result in group {
                if let (url, name) = result { cached[url] = name }
                if let url = pending.next() { group.addTask { await Self.download(url, into: folder) } }
            }
        }
        return cached
    }

    private static func download(_ url: URL, into folder: URL) async -> (String, String)? {
        let name = Library.artworkName(url)
        let destination = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: destination.path) { return (url.absoluteString, name) }
        do {
            let (temporary, response) = try await URLSession.shared.download(for: URLRequest(url: url, timeoutInterval: 15))
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  CGImageSourceCreateWithURL(temporary as CFURL, nil) != nil else { return nil }
            try FileManager.default.moveItem(at: temporary, to: destination)
            return (url.absoluteString, name)
        } catch { return nil }
    }
}
