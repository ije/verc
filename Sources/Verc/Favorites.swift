import AppKit
import Observation

struct FavoritePage: Identifiable, Codable, Sendable {
    var id = UUID()
    var title = ""
    var media: [URL] = []
    var background: URL?
    var info: TMDBTitle?
    var clearedInfoTitle: String?
    var episodeTitles: [String: String]?
    var episodeImages: [String: URL]?
    var directory: String?
    var cachedArtwork: [String: String]?
    var libraryURL: URL?

    var artworkURLs: Set<URL> {
        Set(([info?.posterURL, info?.backgroundURL].compactMap { $0 }
            + (info?.backgroundURLs ?? []) + Array((episodeImages ?? [:]).values)).filter { !$0.isFileURL })
    }

    func artworkURL(_ url: URL) -> URL {
        guard let libraryURL, let directory, let name = cachedArtwork?[url.absoluteString] else { return url }
        return libraryURL.appendingPathComponent(directory, isDirectory: true).appendingPathComponent("Artwork", isDirectory: true).appendingPathComponent(name)
    }

    var editTitle: String { info?.mediaType == .tv ? "Edit TV Show" : info?.mediaType == .movie ? "Edit Movie" : "Edit Media" }

    var lookupKey: [String] { [title] + media.map(\.absoluteString) }
    var missingSeasons: [Int] {
        guard info?.mediaType == .tv else { return [] }
        return Set(media.compactMap { url -> Int? in
            let item = MediaItem(url: url)
            guard item.isVideo else { return nil }
            let filename = MediaFilename(item.title)
            guard let key = filename.episodeKey, episodeTitles?[key] == nil || episodeImages == nil else { return nil }
            return filename.season
        }).sorted()
    }
    var seasonSuffix: String {
        guard info?.mediaType == .tv else { return "" }
        let seasons = Set(media.compactMap { MediaFilename($0.deletingPathExtension().lastPathComponent).season }).sorted()
        return seasons.count > 1 ? " · Seasons \(seasons.map(String.init).joined(separator: ", "))" : ""
    }
    var displayTitle: String { title + seasonSuffix }

    func title(for url: URL) -> String {
        let item = MediaItem(url: url)
        guard let info, item.isVideo else { return item.title }
        let filename = MediaFilename(item.title)
        if info.mediaType == .tv, let key = filename.episodeKey {
            return episodeTitles?[key] ?? item.title
        }
        return media.count == 1 ? info.title : item.title
    }

    func artwork(for url: URL) -> URL? {
        let item = MediaItem(url: url)
        guard let info, item.isVideo else { return nil }
        if info.mediaType == .tv, let key = MediaFilename(item.title).episodeKey {
            return (episodeImages?[key] ?? info.backgroundURL ?? info.posterURL).map(artworkURL)
        }
        return (info.backgroundURL ?? info.posterURL).map(artworkURL)
    }

    static func drafts(for urls: [URL]) async throws -> [FavoritePage] {
        try await Task.detached(priority: .userInitiated) {
            var seen: Set<URL> = []
            let media = try urls.flatMap { url in
                guard url.pathExtension.lowercased() != "verclibrary" else { return [URL]() }
                if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                    return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
                }
                return [url]
            }.map(Library.resolve).filter { seen.insert($0.standardizedFileURL).inserted && MediaItem.isMediaFile($0, images: true) }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            var pages: [FavoritePage] = []
            var groups: [[String]: Int] = [:]
            for url in media {
                let item = MediaItem(url: url)
                let folder = url.deletingLastPathComponent()
                let filename = MediaFilename(item.title)
                var title = folder.lastPathComponent
                let key: [String]
                if !item.isVideo {
                    key = ["local", folder.absoluteString]
                } else {
                    let folderTitle = MediaFilename(title).title
                    title = filename.title.isEmpty ? (folderTitle.isEmpty ? MediaFilename(folder.deletingLastPathComponent().lastPathComponent).title : folderTitle) : filename.title
                    key = [filename.season == nil ? "movie" : "tv", title.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")), filename.year.map(String.init) ?? ""]
                }
                if let index = groups[key] { pages[index].media.append(url) }
                else {
                    groups[key] = pages.count
                    pages.append(FavoritePage(title: title, media: [url]))
                }
            }
            return pages
        }.value
    }

    mutating func loadEpisodes() async throws -> Bool {
        guard let info, info.mediaType == .tv else { return true }
        let seasons = missingSeasons
        let responses = await withTaskGroup(of: TMDB.Response?.self) { group in
            for season in seasons { group.addTask { try? await TMDB.load(.init(type: "tv", id: info.id, season: season)) } }
            return await group.reduce(into: [TMDB.Response?]()) { $0.append($1) }
        }
        try Task.checkCancellation()
        var titles = episodeTitles ?? [:]
        var images = episodeImages ?? [:]
        for episode in responses.flatMap({ $0?.episodes ?? [] }) {
            let key = MediaFilename.episodeKey(episode.season, episode.episode)
            titles[key] = episode.title
            images[key] = episode.stillURL
        }
        episodeTitles = titles
        episodeImages = images
        return !responses.contains { $0 == nil }
    }
}

@MainActor @Observable final class FavoritePages {
    var pages: [FavoritePage] = [] {
        didSet { if ready && !applying { persist() } }
    }
    private var store: LibraryStore?
    private var loadTask: Task<Void, Never>?
    private var draftTask: Task<Void, Never>?
    private var persistence: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var applying = false
    private var queued = false
    private(set) var url: URL?
    private(set) var opening = false
    var ready: Bool { store != nil && !opening }
    private(set) var saving = false
    var error: String?
    private(set) var selection: UUID?
    private(set) var forward = true
    var previewSelection: URL?
    var showAllMedia = false
    var draft: [FavoritePage]?
    var pendingDeletion: FavoritePage?
    var selectedPage: FavoritePage? { pages.first { $0.id == selection } }

    func load(_ url: URL, create: Bool = false, showLibrary: Bool = false) {
        guard !saving else { error = "Wait for the files to finish importing before opening another library."; return }
        let previousLoad = loadTask
        previousLoad?.cancel()
        artworkTask?.cancel()
        draftTask?.cancel()
        opening = true
        let previousSave = persistence
        let url = URL(fileURLWithPath: url.path, isDirectory: true).standardizedFileURL
        let store = LibraryStore(url: url)
        loadTask = Task {
            await previousLoad?.value
            await previousSave?.value
            guard !Task.isCancelled else { return }
            do {
                let pages = try await store.load(create: create)
                try Task.checkCancellation()
                self.store = store
                self.url = url
                applying = true
                self.pages = pages
                applying = false
                UserDefaults.standard.set(url.path, forKey: "libraryPath")
                select(nil)
                showAllMedia = showLibrary
                error = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.error = "The library could not be opened. \(error.localizedDescription)"
            }
            opening = false
            loadTask = nil
            cacheArtwork()
        }
    }

    func flush() async { await persistence?.value }

    // A pending save can remove an item, and its originals can then be added again.
    func copiedSources() async -> Set<URL> {
        await persistence?.value
        return await store?.copiedSources() ?? []
    }

    // A queued save reads pages when it runs, so it also covers later changes. Saving an older list would move imported files back.
    private func persist() {
        guard let store, !queued else { return }
        queued = true
        let previous = persistence
        persistence = Task {
            await previous?.value
            queued = false
            do { _ = try await store.save(pages) }
            catch { self.error = "The library could not be saved. \(error.localizedDescription)" }
        }
    }

    func save(_ pages: [FavoritePage], importing ids: Set<UUID>, moving: Set<URL> = []) async -> Bool {
        guard ready, !saving, let store else { return false }
        saving = true
        defer { saving = false; cacheArtwork() }
        artworkTask?.cancel()
        let previous = persistence
        let task = Task {
            await previous?.value
            do {
                let saved = try await store.save(pages, importing: ids, moving: moving)
                applying = true
                self.pages = saved
                applying = false
                return true
            } catch {
                self.error = "The files could not be added to the library. \(error.localizedDescription)"
                return false
            }
        }
        persistence = Task { _ = await task.value }
        return await task.value
    }

    private func cacheArtwork() {
        guard ready, !saving, let store else { return }
        artworkTask?.cancel()
        let snapshot = pages
        artworkTask = Task {
            var changed = false
            for var page in snapshot {
                guard !Task.isCancelled else { return }
                if let info = page.info, info.backgroundURLs == nil,
                   let response = try? await TMDB.load(.init(type: info.mediaType.rawValue, id: info.id)) {
                    page.info?.backgroundURLs = response.backgroundURLs
                }
                if let info = page.info, info.credits == nil,
                   let response = try? await TMDB.load(.init(type: info.mediaType.rawValue, id: info.id, credits: true)) {
                    page.info?.credits = response.credits
                }
                let cached = await store.cacheArtwork(page)
                guard !Task.isCancelled else { return }
                guard let index = pages.firstIndex(where: { $0.id == page.id && $0.info?.url == page.info?.url }),
                      pages[index].info?.backgroundURLs != page.info?.backgroundURLs || pages[index].info?.credits != page.info?.credits
                        || pages[index].cachedArtwork != cached else { continue }
                applying = true
                pages[index].info?.backgroundURLs = page.info?.backgroundURLs
                pages[index].info?.credits = page.info?.credits
                pages[index].cachedArtwork = cached
                applying = false
                changed = true
            }
            if changed { persist() }
        }
    }

    @discardableResult func open(_ urls: [URL], player: PlayerModel, create: Bool = false) -> Bool {
        guard let url = urls.last(where: { $0.isFileURL && $0.pathExtension.lowercased() == "verclibrary" }) else { return false }
        guard !saving else { error = "Wait for the files to finish importing before opening another library."; return true }
        player.stop()
        player.showInfo = false
        player.showURL = false
        player.showIconPicker = false
        draft = nil
        pendingDeletion = nil
        load(url, create: create, showLibrary: true)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func select(_ id: UUID?) {
        let ids = [nil] + pages.map { Optional($0.id) }
        forward = (ids.firstIndex(of: id) ?? 0) > (ids.firstIndex(of: selection) ?? 0)
        selection = id
        previewSelection = nil
        showAllMedia = false
    }

    func remove(_ page: FavoritePage) {
        if selection == page.id { select(nil) }
        pages.removeAll { $0.id == page.id }
    }

    func movePage(by offset: Int) {
        let ids = [nil] + pages.map { Optional($0.id) }
        let next = (ids.firstIndex(of: selection) ?? 0) + offset
        if ids.indices.contains(next) { select(ids[next]) }
    }

    func movePreview(by offset: Int) {
        guard let page = selectedPage else { return }
        let next = (previewSelection.flatMap { page.media.firstIndex(of: $0) } ?? (page.info == nil ? 0 : -1)) + offset
        if page.media.indices.contains(next) { previewSelection = page.media[next] }
        else if next == -1, let info = page.info { previewSelection = info.url }
    }

    func prepareDraft(_ urls: [URL], player: PlayerModel) {
        guard ready, !saving, !urls.isEmpty else { return }
        draftTask?.cancel()
        draftTask = Task {
            do {
                var pages = try await FavoritePage.drafts(for: urls)
                let copied = await copiedSources()
                try Task.checkCancellation()
                guard !pages.isEmpty else { player.error = "This selection contains no supported media files."; return }
                let existing = Set(self.pages.flatMap(\.media).map(\.standardizedFileURL)).union(copied)
                for index in pages.indices { pages[index].media.removeAll { existing.contains($0.standardizedFileURL) } }
                pages.removeAll { $0.media.isEmpty }
                guard !pages.isEmpty else { player.error = "No files were added. All selected files are already in your library."; return }
                draft = pages
            } catch {
                if !Task.isCancelled { player.error = "These files or folders are unavailable. Choose them from their current location." }
            }
        }
    }
}
