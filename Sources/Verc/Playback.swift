import AppKit
import VLC
import Foundation
import ImageIO
import MediaPlayer
import Observation
import Synchronization
import UniformTypeIdentifiers

struct MediaItem: Identifiable {
    let id = UUID()
    let url: URL
    var duration: Double?
    var subtitles: [URL] = []
    var name: String?
    var artwork: URL?
    var title: String { name ?? (url.isFileURL ? url.deletingPathExtension().lastPathComponent : ["", "/"].contains(url.lastPathComponent) ? url.host ?? "Stream" : url.lastPathComponent) }
    var isAudio: Bool { Self.audioExtensions.contains(url.pathExtension.lowercased()) || UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) == true }
    var isImage: Bool { UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true }
    var isVideo: Bool { !isAudio && !isImage }
    var detail: String { url.isFileURL ? url.pathExtension.uppercased() : "Stream" }
    private static let fileExtensions: [String: Set<String>] = {
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]] ?? []
        return types.reduce(into: [:]) { result, type in
            guard let name = type["CFBundleTypeName"] as? String,
                  let extensions = type["CFBundleTypeExtensions"] as? [String] else { return }
            result[name] = Set(extensions)
        }
    }()
    static let audioExtensions = fileExtensions["Audio"] ?? []
    static let videoExtensions = fileExtensions["Video"] ?? []
    static let subtitleExtensions = fileExtensions["Subtitles"] ?? []
    static let playlistExtensions = fileExtensions["Playlists"] ?? []
    static let streamSchemes: Set<String> = ["http", "https", "rtsp", "rtp", "udp", "srt"]
    static let libraryTypes: [UTType] = [.folder, .audio, .movie, .image] + audioExtensions.union(videoExtensions).compactMap { UTType(filenameExtension: $0) }

    static func subtitleName(_ name: String) -> String {
        name.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    // Reads file attributes, so call it off the main thread.
    static func isMediaFile(_ url: URL, images: Bool = false) -> Bool {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return false }
        let ext = url.pathExtension.lowercased()
        guard !subtitleExtensions.contains(ext) else { return false }
        if audioExtensions.contains(ext) || videoExtensions.contains(ext) { return true }
        let type = UTType(filenameExtension: ext)
        return type?.conforms(to: .audio) == true || type?.conforms(to: .movie) == true || images && type?.conforms(to: .image) == true
    }

    // Reads the file system, so call it off the main thread. Each folder is read once for all of its media.
    static func subtitleFiles(for urls: [URL], cancelled: () -> Bool = { false }) -> [URL: [URL]] {
        var result: [URL: [URL]] = [:]
        for (folder, media) in Dictionary(grouping: urls.filter(\.isFileURL), by: { $0.deletingLastPathComponent().resolvingSymlinksInPath() }) {
            let targets = media.map { url in
                (url: url, name: subtitleName(url.deletingPathExtension().lastPathComponent), companions: ["Subs", "Subtitles"].map {
                    folder.appendingPathComponent($0, isDirectory: true).appendingPathComponent(url.lastPathComponent, isDirectory: true).path + "/"
                })
            }.filter { !$0.name.isEmpty }
            guard !targets.isEmpty, let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                                               options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }) else { continue }
            let companions = targets.flatMap(\.companions)
            let library = folder.pathComponents.contains { $0.hasSuffix(".verclibrary") }
            var names = Set(targets.map(\.name))
            var found: [(url: URL, path: String, name: String, folder: String, nested: Bool)] = []
            for case let entry as URL in files {
                guard !cancelled() else { return [:] }
                let file = entry.standardizedFileURL
                let path = file.path
                if (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    // Enter only subtitle folders, so a large folder such as Downloads does not delay playback.
                    let title = " " + subtitleName(file.lastPathComponent) + " "
                    if !companions.contains(where: path.hasPrefix) && (files.level > 2 || files.level == 1 && !targets.contains { title.contains(" " + $0.name + " ") }
                        && !["sub", "subs", "subtitle", "subtitles"].contains(where: { title.contains(" \($0) ") })) {
                        files.skipDescendants()
                    }
                    continue
                }
                let ext = file.pathExtension.lowercased()
                let isMedia = audioExtensions.contains(ext) || videoExtensions.contains(ext)
                guard isMedia || subtitleExtensions.contains(ext) else { continue }
                let title = subtitleName(file.deletingPathExtension().lastPathComponent)
                if isMedia { names.insert(title); continue }
                let relative = path.dropFirst(folder.path.count)
                found.append((file, path, title, subtitleName(file.deletingLastPathComponent().lastPathComponent),
                              relative.contains("/Subs/") || relative.contains("/Subtitles/")))
            }
            // Match the longest media name, so "Show S01E01" does not take the subtitles of "Show S01E01 Extended".
            let ordered = names.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
            let owners = found.map { subtitle in ordered.first { (" " + subtitle.name + " ").contains(" " + $0 + " ") } }
            for target in targets {
                var subtitles: [URL] = [], matched: [URL] = []
                for (subtitle, owner) in zip(found, owners) {
                    if target.companions.contains(where: subtitle.path.hasPrefix) { subtitles.append(subtitle.url) }
                    else if (!library || !subtitle.nested) && (subtitle.folder == target.name || owner == target.name) { matched.append(subtitle.url) }
                }
                result[target.url] = subtitles + matched
            }
        }
        return result
    }
}

struct MediaTrack: Identifiable, Equatable, Sendable {
    let id: Int32
    let name: String
    var isExternal = false
    var format: String?
}

struct PlaybackProgress: Codable, Equatable {
    let time: Double
    let duration: Double
    let finished: Bool
    var date: Date?
    var fraction: Double { finished ? 1 : min(1, max(0, time / duration)) }
}

enum RepeatMode: String, CaseIterable {
    case off = "Off", all = "All", one = "One"
}

struct PlaybackSnapshot: Sendable {
    let id: UUID
    let state: Int32
    let time: Double
    let duration: Double
    let seekable: Bool
    let width: UInt32
    let height: UInt32
    let ratio: CGSize
    let audio: [MediaTrack]
    let subtitles: [MediaTrack]
    let audioID: Int32
    let subtitleID: Int32
}

enum PlaybackCommand: Sendable {
    case open(URL, UUID, Double), pause(Bool), seek(Double), volume(Double), rate(Float)
    case track(Int32, Bool), subtitle(URL), crop(String?), stop
    case subtitleLayout(width: Double, height: Double, bottomInset: Double, fontSize: Double, font: String)
}

private enum MediaCommand: Sendable {
    case play, pause, toggle, stop, previous, next, backward, forward, position
}

final class MediaDetails: Sendable {
    let duration: Double?
    let width: UInt32
    let height: UInt32
    let subtitleCount: Int?

    init(duration: Double? = nil, width: UInt32 = 0, height: UInt32 = 0, subtitleCount: Int? = nil) {
        self.duration = duration
        self.width = width
        self.height = height
        self.subtitleCount = subtitleCount
    }
}

final class MediaPreview: Sendable {
    let image: CGImage?
    let duration: Double?

    init(image: CGImage? = nil, duration: Double? = nil) {
        self.image = image
        self.duration = duration
    }
}

final class VLC: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.verc.playback", qos: .userInitiated)
    private let metadataQueue = DispatchQueue(label: "app.verc.metadata", qos: .utility)
    // Previews can block for seconds, so they must not delay playlist reads.
    private let previewQueue = DispatchQueue(label: "app.verc.preview", qos: .utility)
    private let searchQueue = DispatchQueue(label: "app.verc.subtitles", qos: .userInitiated)
    private let previews = NSCache<NSURL, MediaPreview>()
    private let mediaDetails = NSCache<NSURL, MediaDetails>()
    private var handle: OpaquePointer?
    private var timer: DispatchSourceTimer?
    private var mediaID = UUID()
    private let closed = Atomic(false)
    private let requests = Atomic(0)
    private var externalSubtitles = false
    private var embeddedSubtitleCount: Int?
    private var subtitleFiles: [URL] = []
    private var subtitleFormats: [String] = []
    private var endTime: UInt64?
    var onUpdate: (@Sendable (PlaybackSnapshot) -> Void)?
    var onError: (@Sendable (String) -> Void)?

    /// Loads libVLC on the playback queue: it opens every bundled plugin, which would otherwise delay launch.
    init(view address: UInt, onStart: @escaping @Sendable (Result<String, any Error>) -> Void) {
        previews.totalCostLimit = 96 * 1024 * 1024
        previews.countLimit = 128
        queue.async { [self] in
            do {
                let loaded = try Self.load()
                vc_drawable(loaded, UnsafeMutableRawPointer(bitPattern: address))
                handle = loaded
                onStart(.success(String(cString: vc_version(loaded))))
            } catch { onStart(.failure(error)) }
        }
    }

    private static func load() throws -> OpaquePointer {
        guard let path = Bundle.main.privateFrameworksURL?.appendingPathComponent("VLC").path,
              FileManager.default.fileExists(atPath: path + "/lib/libvlc.dylib") else {
            throw NSError(domain: "Verc", code: 1, userInfo: [NSLocalizedDescriptionKey: "The bundled playback engine is missing. Rebuild or reinstall Verc."])
        }
        var error = [CChar](repeating: 0, count: 4096)
        guard let loaded = vc_create(path, &error, Int32(error.count)) else {
            let failure = String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            throw NSError(domain: "Verc", code: 1, userInfo: [NSLocalizedDescriptionKey: failure])
        }
        return loaded
    }

    func send(_ command: PlaybackCommand) {
        // A later open or stop cancels the subtitle search of an earlier open.
        let request = switch command {
        case .open, .stop: requests.wrappingAdd(1, ordering: .relaxed).newValue
        default: 0
        }
        if case let .open(url, id, time) = command {
            // The subtitle search can take seconds on a network volume, so it runs before the playback queue.
            searchQueue.async { [self] in
                let current: @Sendable () -> Bool = { [self] in requests.load(ordering: .relaxed) == request }
                // VLC loads the subtitles next to the media by itself.
                let folder = url.deletingLastPathComponent().resolvingSymlinksInPath().path
                let found = (MediaItem(url: url).isImage ? [:] : MediaItem.subtitleFiles(for: [url]) { !current() })[url, default: []]
                    .filter { $0.deletingLastPathComponent().path != folder }
                guard current() else { return }
                let indexes = Set(found.filter { $0.pathExtension.lowercased() == "idx" }.map { $0.deletingPathExtension().path.lowercased() })
                let subtitles = found.filter { $0.pathExtension.lowercased() != "sub" || !indexes.contains($0.deletingPathExtension().path.lowercased()) }
                    .sorted { $0.path < $1.path }
                queue.async { [self] in
                    guard !closed.load(ordering: .relaxed), let handle, current() else { return }
                    mediaID = id
                    externalSubtitles = !subtitles.isEmpty
                    embeddedSubtitleCount = nil
                    subtitleFiles = []
                    subtitleFormats = []
                    endTime = nil
                    Task {
                        let details = await details(of: url)
                        queue.async { [self] in
                            if mediaID == id, let count = details.subtitleCount { embeddedSubtitleCount = count }
                        }
                    }
                    let strings = subtitles.compactMap { strdup($0.absoluteString) }
                    defer { for string in strings { free(string) } }
                    let uris: [UnsafePointer<CChar>?] = strings.map { UnsafePointer($0) }
                    let result = uris.withUnsafeBufferPointer { vc_open(handle, url.absoluteString, time, $0.baseAddress, Int32($0.count)) }
                    if result != 0 { onError?("This media could not be opened. Check the file or stream address.") }
                    if timer == nil {
                        let source = DispatchSource.makeTimerSource(queue: queue)
                        source.setEventHandler { [weak self] in self?.publish() }
                        source.activate()
                        timer = source
                    }
                    timer?.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(50))
                }
            }
            return
        }
        queue.async { [self] in
            guard !closed.load(ordering: .relaxed), let handle else { return }
            switch command {
            case .open: break
            case let .pause(paused):
                vc_pause(handle, paused ? 1 : 0)
                timer?.schedule(deadline: .now(), repeating: .milliseconds(paused ? 1000 : 250), leeway: .milliseconds(50))
            case let .seek(seconds):
                endTime = nil
                vc_seek(handle, Int64(max(0, seconds) * 1000))
            case let .volume(volume): vc_volume(handle, Int32((volume * 100).rounded()))
            case let .rate(rate):
                if vc_rate(handle, rate) != 0 { onError?("Verc cannot change the playback speed for this media.") }
            case let .track(id, subtitles):
                if vc_select_track(handle, subtitles ? 1 : 0, id) != 0 { onError?("The selected track is unavailable.") }
            case let .subtitle(url):
                if embeddedSubtitleCount == nil, !externalSubtitles {
                    let head = vc_tracks(handle, 1)
                    var node = head
                    var count = 0
                    while let track = node?.pointee {
                        if track.id != -1 { count += 1 }
                        node = track.next
                    }
                    if let head { vc_free_tracks(handle, head) }
                    embeddedSubtitleCount = count
                }
                if vc_add_subtitle(handle, url.absoluteString) != 0 { onError?("This subtitle file could not be loaded.") }
                else { externalSubtitles = true }
            case let .subtitleLayout(width, height, bottomInset, fontSize, font):
                vc_subtitle_layout(handle, VCSubtitleLayout(width: width, height: height, bottomInset: bottomInset, fontSize: fontSize), font)
            case let .crop(geometry):
                if let geometry { vc_crop(handle, geometry) }
                else { vc_crop(handle, nil) }
            case .stop:
                vc_stop(handle)
                timer?.schedule(deadline: .distantFuture)
            }
        }
    }

    private func publish() {
        guard let handle else { return }
        var width: UInt32 = 0
        var height: UInt32 = 0
        var ratioWidth: UInt32 = 0
        var ratioHeight: UInt32 = 0
        _ = vc_video_size(handle, &width, &height, &ratioWidth, &ratioHeight)
        var slaves: UnsafeMutablePointer<UnsafeMutablePointer<VCMediaSlave>?>?
        let count = vc_media_slaves(handle, &slaves)
        let files = UnsafeBufferPointer(start: slaves, count: Int(count)).compactMap { slave -> URL? in
            guard let slave = slave?.pointee, slave.type == 0, let uri = slave.uri else { return nil }
            return URL(string: String(cString: uri))
        }
        if let slaves { vc_free_media_slaves(handle, slaves, count) }
        if subtitleFiles != files {
            subtitleFiles = files
            let id = mediaID
            Task {
                var formats: [String] = []
                for file in files {
                    let format = file.pathExtension.lowercased()
                    let count = ["idx", "mks", "usf"].contains(format) ? await details(of: file).subtitleCount ?? 1 : 1
                    formats += Array(repeating: format, count: max(1, count))
                }
                let loaded = formats
                queue.async { [self] in
                    if mediaID == id, subtitleFiles == files { subtitleFormats = loaded }
                }
            }
        }
        var groups: [[MediaTrack]] = []
        for subtitles: Int32 in [0, 1] {
            let head = vc_tracks(handle, subtitles)
            var node = head
            var tracks: [MediaTrack] = []
            var index = 0
            while let track = node?.pointee {
                // VLC 3 appends subtitle files after the media's embedded tracks.
                let isExternal = subtitles == 1 && track.id != -1 && embeddedSubtitleCount.map { index >= $0 } == true
                let fileIndex = index - (embeddedSubtitleCount ?? 0)
                let format = isExternal && subtitleFormats.indices.contains(fileIndex) ? subtitleFormats[fileIndex] : nil
                tracks.append(MediaTrack(id: track.id, name: track.id == -1 ? "Off" : track.name.map { String(cString: $0) } ?? "Track \(track.id)", isExternal: isExternal, format: format))
                if track.id != -1 { index += 1 }
                node = track.next
            }
            if let head { vc_free_tracks(handle, head) }
            groups.append(tracks)
        }
        var state = vc_state(handle)
        if state == 6 && vc_failed(handle) != 0 { state = 7 }
        let time = max(0, Double(vc_time(handle)) / 1000)
        let duration = max(0, Double(vc_duration(handle)) / 1000)
        let seekable = vc_seekable(handle) != 0
        // VLC 3 can remain in the playing state at EOF after an external subtitle is attached.
        if externalSubtitles && state == 3 && seekable && duration > 0 && time >= duration {
            let now = DispatchTime.now().uptimeNanoseconds
            if let endTime, now - endTime >= 2_000_000_000 {
                vc_stop(handle)
                state = 6
            } else if endTime == nil { endTime = now }
        } else { endTime = nil }
        onUpdate?(PlaybackSnapshot(
            id: mediaID, state: state, time: time,
            duration: duration, seekable: seekable,
            width: width, height: height, ratio: CGSize(width: Double(ratioWidth), height: Double(ratioHeight)),
            audio: groups[0], subtitles: groups[1],
            audioID: vc_selected_track(handle, 0), subtitleID: vc_selected_track(handle, 1)
        ))
        if state == 6 || state == 7 { timer?.schedule(deadline: .distantFuture) }
    }

    func saveFrame(to url: URL, id: UUID) async throws -> CGImage? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard !closed.load(ordering: .relaxed), let handle, mediaID == id, [3, 4].contains(vc_state(handle)) else {
                    continuation.resume(returning: nil)
                    return
                }
                let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
                defer { try? FileManager.default.removeItem(at: temporary) }
                do {
                    // VLC can return success even when encoding or writing the snapshot fails.
                    guard vc_snapshot(handle, temporary.path) == 0,
                          let image = thumbnail(CGImageSourceCreateWithURL(temporary as CFURL, nil), maxPixelSize: 480) else {
                        throw NSError(domain: "Verc", code: 2, userInfo: [NSLocalizedDescriptionKey: "The current video frame could not be captured. Try again when the video is ready."])
                    }
                    try FileManager.default.moveItem(at: temporary, to: url)
                    continuation.resume(returning: image)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func duration(of url: URL) async -> Double? {
        await details(of: url).duration
    }

    func details(of url: URL) async -> MediaDetails {
        if let cached = mediaDetails.object(forKey: url as NSURL) { return cached }
        return await metadata(MediaDetails()) { [self] handle in
            let info = vc_read_media_info(handle, url.absoluteString)
            let details = MediaDetails(duration: info.duration > 0 ? Double(info.duration) / 1000 : nil, width: info.width, height: info.height,
                                       subtitleCount: info.subtitleCount >= 0 ? Int(info.subtitleCount) : nil)
            if details.duration != nil || details.width > 0 { mediaDetails.setObject(details, forKey: url as NSURL) }
            return details
        }
    }

    func preview(of url: URL) async -> MediaPreview {
        guard url.isFileURL else { return MediaPreview() }
        if let cached = previews.object(forKey: url as NSURL) { return cached }
        let item = MediaItem(url: url)
        let preview: MediaPreview
        if item.isImage {
            preview = await Task.detached(priority: .utility) {
                MediaPreview(image: thumbnail(CGImageSourceCreateWithURL(url as CFURL, nil), maxPixelSize: 960))
            }.value
        } else {
            let video = item.isVideo
            let cancelled = Mutex(false)
            preview = await withTaskCancellationHandler {
                await metadata(MediaPreview(), on: previewQueue) { handle in
                    guard !cancelled.withLock({ $0 }) else { return MediaPreview() }
                    var result = vc_read_preview(handle, url.absoluteString, video ? 1 : 0)
                    defer { vc_free_preview(&result) }
                    var image: CGImage?
                    if let pixels = result.pixels,
                       let provider = CGDataProvider(dataInfo: nil, data: pixels, size: Int(result.pitch * result.height),
                                                     releaseData: { _, data, _ in free(UnsafeMutableRawPointer(mutating: data)) }) {
                        result.pixels = nil
                        image = CGImage(width: Int(result.width), height: Int(result.height), bitsPerComponent: 8, bitsPerPixel: 32,
                                        bytesPerRow: Int(result.pitch), space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)],
                                        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
                    } else if let artwork = result.artwork.flatMap({ URL(string: String(cString: $0)) }), artwork.isFileURL {
                        image = thumbnail(CGImageSourceCreateWithURL(artwork as CFURL, nil), maxPixelSize: 960)
                    }
                    return MediaPreview(image: image, duration: result.duration > 0 ? Double(result.duration) / 1000 : nil)
                }
            } onCancel: { cancelled.withLock { $0 = true } }
        }
        // An empty result can be a slow or sleeping disk, so read it again next time.
        if preview.image != nil || preview.duration != nil {
            previews.setObject(preview, forKey: url as NSURL, cost: preview.image.map { $0.bytesPerRow * $0.height } ?? 1)
        }
        return preview
    }

    func entries(of url: URL) async -> [URL] {
        await metadata([]) { handle in
            guard let entries = vc_read_playlist(handle, url.absoluteString) else { return [] }
            var urls: [URL] = []
            var cursor = entries
            while let entry = cursor.pointee {
                if let url = URL(string: String(cString: entry)) { urls.append(url) }
                cursor += 1
            }
            vc_free_playlist(entries)
            return urls
        }
    }

    private func metadata<T: Sendable>(_ fallback: T, on target: DispatchQueue? = nil, _ body: @escaping @Sendable (OpaquePointer?) -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard !closed.load(ordering: .relaxed), handle != nil else { continuation.resume(returning: fallback); return }
                // Shutdown waits for queued work, so skip work that starts after it.
                (target ?? metadataQueue).async { [self] in
                    continuation.resume(returning: closed.load(ordering: .relaxed) ? fallback : body(handle))
                }
            }
        }
    }

    func shutdown(_ completion: @escaping @Sendable () -> Void) {
        requests.wrappingAdd(1, ordering: .relaxed)
        queue.async { [self] in
            if !closed.exchange(true, ordering: .relaxed) {
                timer?.cancel()
                timer = nil
            }
            metadataQueue.async { [self] in
                previewQueue.async { [self] in
                    queue.async { [self] in
                        if let handle { vc_destroy(handle); self.handle = nil }
                        completion()
                    }
                }
            }
        }
    }
}

@MainActor @Observable final class PlayerModel {
    static let subtitleFonts = NSFontManager.shared.availableFontFamilies.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    var current: MediaItem?
    private(set) var playlist: [MediaItem] = []
    private(set) var playlistTitle: String?
    private(set) var progress: [URL: PlaybackProgress] = [:]
    var state: Int32 = 0
    var time = 0.0
    var duration = 0.0
    var seekable = false
    private(set) var seekSeconds: Double?
    var videoWidth: UInt32 = 0
    var videoHeight: UInt32 = 0
    var videoRatio = CGSize.zero
    var audioTracks: [MediaTrack] = []
    var subtitleTracks: [MediaTrack] = []
    var audioID: Int32 = -1
    var subtitleID: Int32 = -1
    var subtitleFont = "Helvetica Neue" {
        didSet {
            UserDefaults.standard.set(subtitleFont, forKey: "subtitleFont")
            (videoView.superview as? SubtitleSurface)?.updateSubtitleLayout()
        }
    }
    var subtitleFontSize = 36.0 {
        didSet { (videoView.superview as? SubtitleSurface)?.updateSubtitleLayout() }
    }
    var subtitleBottomInset = 42.0 {
        didSet { (videoView.superview as? SubtitleSurface)?.updateSubtitleLayout() }
    }
    var volume = 0.8 {
        didSet { send(.volume(muted ? 0 : volume)) }
    }
    var muted = false {
        didSet { send(.volume(muted ? 0 : volume)) }
    }
    var speed: Float = 1 {
        didSet { send(.rate(speed)); updateNowPlaying() }
    }
    var repeatMode = RepeatMode.off { didSet { updateNowPlaying() } }
    var fillVideo = UserDefaults.standard.object(forKey: "fillVideo") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(fillVideo, forKey: "fillVideo")
            updateCrop()
        }
    }
    var isFullScreen = false {
        didSet { if isFullScreen != oldValue { fillVideo = !isFullScreen } }
    }
    var viewport = CGSize.zero { didSet { updateCrop() } }
    var showURL = false
    var showIconPicker = false
    var showInfo = false {
        didSet { if showInfo { endPictureInPicture() } }
    }
    var error: String?
    var engineError: String?
    var engineVersion: String?
    var isPictureInPicture = false
    private var isSavingFrame = false
    @ObservationIgnored let videoView = NSView()
    @ObservationIgnored private(set) var engine: VLC?
    @ObservationIgnored private var sleepActivity: NSObjectProtocol?
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var playbackID = UUID()
    @ObservationIgnored private var pictureInPicture: PictureInPicture?
    @ObservationIgnored private var framePreview: FramePreview?
    @ObservationIgnored private var durationTask: Task<Void, Never>?
    @ObservationIgnored private var addTask: Task<Void, Never>?
    @ObservationIgnored private var seekFeedbackTask: Task<Void, Never>?
    @ObservationIgnored private var seekOrigin = 0.0
    @ObservationIgnored private var seekTarget = 0.0
    @ObservationIgnored private var lastProgressSave = Date.distantPast
    @ObservationIgnored private var sentCrop: String?
    var canPictureInPicture: Bool { isPictureInPicture || (current != nil && videoWidth > 0 && videoHeight > 0) }
    var canSaveFrame: Bool { current?.isAudio == false && videoWidth > 0 && videoHeight > 0 && (state == 3 || state == 4) && !isSavingFrame }
    var isPlaying: Bool { state == 3 }
    var isLoading: Bool { current != nil && (state == 0 || state == 1 || state == 2) }
    var playLabel: String { isPlaying ? "Pause" : state == 6 ? "Play Again" : "Play" }
    var pictureInPictureLabel: String { isPictureInPicture ? "Exit Picture in Picture" : "Enter Picture in Picture" }
    init() {
        if let data = UserDefaults.standard.data(forKey: "playbackProgress"),
           let saved = try? JSONDecoder().decode([URL: PlaybackProgress].self, from: data) {
            progress = saved.filter { $0.value.time >= 0 && $0.value.duration > 0 }
        }
        if let font = UserDefaults.standard.string(forKey: "subtitleFont"), NSFontManager.shared.availableMembers(ofFontFamily: font) != nil { subtitleFont = font }
        videoView.wantsLayer = true
        videoView.layer?.backgroundColor = NSColor.black.cgColor
        let engine = VLC(view: UInt(bitPattern: Unmanaged.passUnretained(videoView).toOpaque())) { [weak self] result in
            Task { @MainActor in self?.engineStarted(result) }
        }
        engine.onError = { [weak self] message in Task { @MainActor in self?.error = message } }
        engine.onUpdate = { [weak self] snapshot in
            Task { @MainActor in self?.receive(snapshot) }
        }
        self.engine = engine
        let commands = MPRemoteCommandCenter.shared()
        commands.skipBackwardCommand.preferredIntervals = [10]
        commands.skipForwardCommand.preferredIntervals = [10]
        let handlers: [(MPRemoteCommand, MediaCommand)] = [
            (commands.playCommand, .play), (commands.pauseCommand, .pause),
            (commands.togglePlayPauseCommand, .toggle), (commands.stopCommand, .stop),
            (commands.previousTrackCommand, .previous), (commands.nextTrackCommand, .next),
            (commands.skipBackwardCommand, .backward), (commands.skipForwardCommand, .forward),
            (commands.changePlaybackPositionCommand, .position)
        ]
        for (command, action) in handlers {
            command.addTarget { @Sendable [weak self] event in
                let seconds = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime
                    ?? (event as? MPSkipIntervalCommandEvent)?.interval
                if Thread.isMainThread {
                    return MainActor.assumeIsolated { self?.handleMediaCommand(action, seconds: seconds) ?? .commandFailed }
                }
                return DispatchQueue.main.sync { self?.handleMediaCommand(action, seconds: seconds) ?? .commandFailed }
            }
        }
        updateNowPlaying()
    }

    private func engineStarted(_ result: Result<String, any Error>) {
        switch result {
        case let .success(version):
            engineVersion = version
            // VLC starts at full volume, so set it before the first media plays.
            send(.volume(muted ? 0 : volume))
        case let .failure(failure):
            engineError = failure.localizedDescription
            if current != nil { state = 7; error = engineError }
        }
        updateNowPlaying()
    }

    private func receive(_ snapshot: PlaybackSnapshot) {
        guard current != nil, playbackID == snapshot.id else { return }
        let previous = state
        let changed = state != snapshot.state || Int(duration) != Int(snapshot.duration) || seekable != snapshot.seekable
        state = snapshot.state
        if didStart || !isLoading { time = snapshot.time }
        if snapshot.duration > 0 || !isLoading { duration = snapshot.duration }
        // VLC refines the length of some VBR files on every update, so compare whole seconds.
        if snapshot.duration > 0 && current?.duration.map(Int.init) != Int(snapshot.duration) {
            current?.duration = snapshot.duration
            if let index = playlist.firstIndex(where: { $0.id == current?.id }) {
                playlist[index].duration = snapshot.duration
            }
        }
        seekable = snapshot.seekable
        videoWidth = snapshot.width
        videoHeight = snapshot.height
        if videoRatio != snapshot.ratio {
            videoRatio = snapshot.ratio
            pictureInPicture?.fit(videoRatio)
        }
        if audioTracks != snapshot.audio { audioTracks = snapshot.audio }
        if subtitleTracks != snapshot.subtitles { subtitleTracks = snapshot.subtitles }
        audioID = snapshot.audioID
        subtitleID = snapshot.subtitleID
        if snapshot.state == 3 && !didStart {
            didStart = true
            send(.volume(muted ? 0 : volume))
            send(.rate(speed))
            // Each media needs the crop again, so it must not count as a repeat.
            sentCrop = nil
            updateCrop()
            for url in current?.subtitles ?? [] { send(.subtitle(url)) }
        }
        if isPlaying && sleepActivity == nil {
            // Audio keeps only the system awake, so the display can still sleep.
            sleepActivity = ProcessInfo.processInfo.beginActivity(options: current?.isAudio == true ? .userInitiated : [.userInitiated, .idleDisplaySleepDisabled], reason: "Playing media")
        } else if !isPlaying, let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }
        if state == 6 || (state == 4 && previous != 4) || (time > 0 && Date().timeIntervalSince(lastProgressSave) >= 5) {
            saveProgress()
        }
        if state == 6 && previous != 6 { advance() }
        else if state == 7 && previous != 7 {
            error = "Verc could not play this media. The file may be damaged, or the stream may be unavailable."
        }
        if changed { updateNowPlaying() }
    }

    private func advance() {
        if repeatMode == .one { togglePlay() }
        else if let index = playlist.firstIndex(where: { $0.id == current?.id }) {
            if index + 1 < playlist.count { play(playlist[index + 1]) }
            else if repeatMode == .all, let first = playlist.first { play(first) }
        }
    }

    private func handleMediaCommand(_ command: MediaCommand, seconds: Double?) -> MPRemoteCommandHandlerStatus {
        guard current?.isImage == false, state != 7 else { return .noActionableNowPlayingItem }
        switch command {
        case .play: if !isPlaying { togglePlay() }
        case .pause: send(.pause(true))
        case .toggle: togglePlay()
        case .stop: stop()
        case .previous, .next:
            guard playAdjacent(by: command == .next ? 1 : -1) else { return .noSuchContent }
        case .backward, .forward, .position:
            guard seekable, let seconds, seconds.isFinite, seconds >= 0 else { return .commandFailed }
            if command == .position { seek(to: seconds) }
            else { seek(by: command == .forward ? seconds : -seconds) }
        }
        return .success
    }

    private func updateNowPlaying() {
        let commands = MPRemoteCommandCenter.shared()
        let active = current?.isImage == false && state != 7
        let index = active ? playlist.firstIndex(where: { $0.id == current?.id }) : nil
        commands.playCommand.isEnabled = active
        commands.pauseCommand.isEnabled = active
        commands.togglePlayPauseCommand.isEnabled = active
        commands.stopCommand.isEnabled = active
        commands.previousTrackCommand.isEnabled = active && adjacentIndex(by: -1) != nil
        commands.nextTrackCommand.isEnabled = active && adjacentIndex(by: 1) != nil
        commands.skipBackwardCommand.isEnabled = active && seekable
        commands.skipForwardCommand.isEnabled = active && seekable
        commands.changePlaybackPositionCommand.isEnabled = active && seekable
        let center = MPNowPlayingInfoCenter.default()
        guard active, let current else {
            center.nowPlayingInfo = nil
            center.playbackState = .unknown
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: current.title,
            MPNowPlayingInfoPropertyMediaType: (current.isAudio ? MPNowPlayingInfoMediaType.audio : .video).rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: time,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? speed : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: speed,
            MPNowPlayingInfoPropertyIsLiveStream: !current.url.isFileURL && duration <= 0
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let index {
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = index
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = playlist.count
        }
        center.nowPlayingInfo = info
        let playbackState: MPNowPlayingPlaybackState = isPlaying ? .playing : state == 4 ? .paused : .stopped
        if center.playbackState != playbackState { center.playbackState = playbackState }
    }

    func send(_ command: PlaybackCommand) {
        engine?.send(command)
    }

    func saveProgress(relocating urls: [URL: URL] = [:], copying: Set<URL> = []) {
        if urls.isEmpty {
            guard let current, !current.isImage, didStart, [3, 4, 6].contains(state), seekable || state == 6 else { return }
            let length = duration > 0 ? duration : current.duration ?? 0
            guard length > 0 else { return }
            var saved = PlaybackProgress(time: state == 6 ? length : min(time, length), duration: length, finished: state == 6)
            var previous = progress[current.url]
            previous?.date = nil
            guard previous != saved else { return }
            saved.date = Date()
            progress[current.url] = saved
        } else {
            for (source, destination) in urls {
                if let saved = progress[source] { progress[destination] = saved }
                if !copying.contains(source) { progress[source] = nil }
            }
        }
        // Every save encodes the whole list, so drop the oldest entry past the limit.
        if progress.count > 1000, let oldest = progress.min(by: { ($0.value.date ?? .distantPast) < ($1.value.date ?? .distantPast) }) {
            progress[oldest.key] = nil
        }
        lastProgressSave = Date()
        if let data = try? JSONEncoder().encode(progress) { UserDefaults.standard.set(data, forKey: "playbackProgress") }
    }

    func saveFrame() {
        guard canSaveFrame, let engine else { return }
        let id = playbackID
        let screen = videoView.window?.screen
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "Verc Frame \(formatter.string(from: Date())) \(UUID().uuidString.prefix(8)).png"
        isSavingFrame = true
        Task {
            defer { isSavingFrame = false }
            do {
                let preferences = UserDefaults.standard.persistentDomain(forName: "com.apple.screencapture")
                let location = preferences?["location-screenshot"] as? String ?? preferences?["location"] as? String
                let directory: URL
                if let location, !location.isEmpty {
                    directory = URL(fileURLWithPath: (location as NSString).expandingTildeInPath, isDirectory: true)
                } else {
                    directory = try FileManager.default.url(for: .desktopDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                }
                let url = directory.appendingPathComponent(name)
                guard let image = try await engine.saveFrame(to: url, id: id) else { return }
                framePreview?.close()
                framePreview = FramePreview(url: url, image: image, screen: screen)
            } catch { self.error = "The frame could not be saved. \(error.localizedDescription)" }
        }
    }

    func togglePictureInPicture() {
        if isPictureInPicture { endPictureInPicture(); return }
        guard canPictureInPicture else { return }
        let mainWindow = videoView.window
        isPictureInPicture = true
        updateCrop()
        pictureInPicture = PictureInPicture(player: self, mainWindow: mainWindow)
    }

    func endPictureInPicture() {
        guard let controller = pictureInPicture else { return }
        pictureInPicture = nil
        controller.window.contentView = nil
        controller.window.close()
        isPictureInPicture = false
        updateCrop()
        controller.mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    var openLibrary: (([URL]) -> Bool)?

    func openFiles(subtitles: Bool = false) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = !subtitles
        panel.title = subtitles ? "Add Subtitles" : "Open File"
        panel.prompt = subtitles ? "Add" : "Open"
        if subtitles { panel.allowedContentTypes = MediaItem.subtitleExtensions.compactMap { UTType(filenameExtension: $0) } }
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.add(panel.urls)
        }
    }

    func add(_ urls: [URL], startingAt selected: URL? = nil, page: FavoritePage? = nil) {
        if openLibrary?(urls) == true { return }
        let isSubtitle = { (url: URL) in MediaItem.subtitleExtensions.contains(url.pathExtension.lowercased()) }
        let subtitles = urls.filter(isSubtitle)
        let sources = urls.filter { !isSubtitle($0) }
        guard !sources.isEmpty else { attach(subtitles); return }
        addTask?.cancel()
        addTask = Task { [weak self, engine] in
            let resolved = await Self.resolve(sources, engine: engine, expanding: true)
            guard let self, !Task.isCancelled else { return }
            if let failure = resolved.failure { error = failure }
            let items = resolved.media.map { MediaItem(url: $0, name: page?.title(for: $0), artwork: page?.artwork(for: $0)) }
            guard !items.isEmpty else { attach(subtitles); return }
            guard let index = selected == nil ? 0 : items.firstIndex(where: { $0.url == selected }) else { return }
            if items[index].url.isFileURL { NSDocumentController.shared.noteNewRecentDocumentURL(items[index].url) }
            durationTask?.cancel()
            playlist = items
            playlistTitle = page?.info?.title
            playlist[index].subtitles = subtitles
            play(playlist[index])
            durationTask = Task { [weak self, engine] in
                guard items.count > 1, let engine else { return }
                let readable = items.indices.filter { items[$0].url.isFileURL && !items[$0].isImage }
                var durations: [Int: Double] = [:]
                var applied = ContinuousClock.now
                for index in readable {
                    guard !Task.isCancelled else { return }
                    durations[index] = await engine.duration(of: items[index].url)
                    guard !Task.isCancelled, let self else { return }
                    // Each playlist change redraws the player and rebuilds the menus, so apply durations in batches.
                    guard index == readable.last || ContinuousClock.now - applied >= .milliseconds(500) else { continue }
                    applied = .now
                    var updated = playlist
                    for (index, duration) in durations where updated[index].duration == nil { updated[index].duration = duration }
                    if !durations.isEmpty { playlist = updated }
                    durations = [:]
                }
            }
        }
    }

    @concurrent private nonisolated static func resolve(_ urls: [URL], engine: VLC?, expanding: Bool) async -> (media: [URL], failure: String?) {
        var media: [URL] = []
        var failure: String?
        var folders = 0
        for url in urls {
            let ext = url.pathExtension.lowercased()
            // Remote .m3u8 files are HLS streams, and reading them would only delay playback.
            let isPlaylist = expanding && MediaItem.playlistExtensions.contains(ext) && (url.isFileURL || ext != "m3u8")
            var directory: ObjCBool = false
            let exists = url.isFileURL && FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
            if exists && directory.boolValue {
                folders += 1
                do {
                    let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
                        .map(Library.resolve).filter { MediaItem.isMediaFile($0) }
                        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                    if files.isEmpty { failure = "No audio or video files were found in \(url.lastPathComponent)." }
                    media += files
                } catch { failure = "This folder is unavailable. Open a folder from its current location." }
            } else if url.isFileURL && !exists {
                failure = "This file is unavailable. Open a media file from its current location."
            } else if !url.isFileURL && !MediaItem.streamSchemes.contains(url.scheme?.lowercased() ?? "") {
                failure = "Use a local file or an HTTP, HTTPS, RTSP, RTP, UDP, or SRT stream."
            } else if isPlaylist, let engine {
                let entries = await engine.entries(of: url)
                if entries.isEmpty { media.append(url); continue }
                let nested = await resolve(entries, engine: engine, expanding: false)
                media += nested.media
                failure = nested.failure ?? failure
            } else { media.append(Library.resolve(url)) }
        }
        let videos = media.filter { MediaItem(url: $0).isVideo }
        guard folders > 1, let first = videos.first else { return (media, failure) }
        let reference = MediaFilename(first.deletingPathExtension().lastPathComponent)
        guard !reference.title.isEmpty else { return (media, failure) }
        let related = videos.filter { url in
            let filename = MediaFilename(url.deletingPathExtension().lastPathComponent)
            return reference.title.compare(filename.title, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) == .orderedSame
                && (reference.year == nil || filename.year == nil || reference.year == filename.year)
        }
        // A folder without a match holds a different title, so keep every file.
        guard Set(videos.map { $0.deletingLastPathComponent() }).isSubset(of: related.map { $0.deletingLastPathComponent() }) else { return (media, failure) }
        let unrelated = Set(videos).subtracting(related)
        return (media.filter { !unrelated.contains($0) }, failure)
    }

    private func attach(_ subtitles: [URL]) {
        guard current != nil else {
            if !subtitles.isEmpty { error = "Open a video or audio file before adding subtitles." }
            return
        }
        let index = playlist.firstIndex(where: { $0.id == current?.id })
        for url in subtitles where current?.subtitles.contains(url) == false {
            current?.subtitles.append(url)
            if let index { playlist[index].subtitles.append(url) }
            if didStart { send(.subtitle(url)) }
        }
    }

    func play(_ item: MediaItem, restart: Bool = false) {
        defer { updateNowPlaying() }
        saveProgress()
        seekFeedbackTask?.cancel()
        seekSeconds = nil
        if current?.id != item.id && item.isAudio { endPictureInPicture() }
        current = item
        playbackID = UUID()
        state = 1
        let saved = progress[item.url]
        if !restart, let saved, !saved.finished { time = min(saved.time, saved.duration) }
        else { time = 0 }
        duration = item.duration ?? saved?.duration ?? 0
        seekable = false
        videoWidth = 0
        videoHeight = 0
        videoRatio = .zero
        audioTracks = []
        subtitleTracks = []
        audioID = -1
        subtitleID = -1
        didStart = false
        guard engineError == nil, let engine else { state = 7; error = engineError ?? "The playback engine is unavailable."; return }
        engine.send(.open(item.url, playbackID, time))
    }

    func adjacentIndex(by offset: Int) -> Int? {
        guard let index = playlist.firstIndex(where: { $0.id == current?.id }) else { return nil }
        var target = index + offset
        if repeatMode == .all { target = (target + playlist.count) % playlist.count }
        return playlist.indices.contains(target) && target != index ? target : nil
    }

    @discardableResult func playAdjacent(by offset: Int) -> Bool {
        guard let target = adjacentIndex(by: offset) else { return false }
        play(playlist[target])
        return true
    }

    func togglePlay() {
        guard let item = current else {
            openFiles()
            return
        }
        if state == 6 || state == 7 || state == 5 { play(item, restart: true) }
        else { send(.pause(isPlaying)) }
    }

    func seek(to seconds: Double) {
        guard seekable, seconds.isFinite else { return }
        seekFeedbackTask?.cancel()
        seekSeconds = nil
        time = max(0, min(seconds, duration > 0 ? duration : seconds))
        if duration > 0 && time >= duration {
            // VLC can ignore seeks at EOF; reject old snapshots so the time stays at the end.
            playbackID = UUID()
            state = 6
            seekable = false
            if let activity = sleepActivity { ProcessInfo.processInfo.endActivity(activity); sleepActivity = nil }
            send(.stop)
            saveProgress()
            advance()
        } else { send(.seek(time)) }
        updateNowPlaying()
    }

    func seek(by offset: Double) {
        guard seekable else { return }
        // Snapshots can report the old position until VLC finishes a seek, so count from the pending target.
        let base = seekSeconds == nil ? time : seekTarget
        if seekSeconds?.sign != offset.sign { seekOrigin = base }
        seekTarget = max(0, min(base + offset, duration > 0 ? duration : base + offset))
        let ending = duration > 0 && seekTarget >= duration
        seek(to: seekTarget)
        // A seek to the end can start the next item, which must not count from this target.
        guard !ending || state == 6 else { return }
        // Keep the offset's sign even when the move is zero, so the feedback shows the pressed direction at the ends.
        seekSeconds = Double(signOf: offset, magnitudeOf: seekTarget - seekOrigin)
        seekFeedbackTask = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { seekSeconds = nil }
        }
    }

    private func updateCrop() {
        guard viewport.width > 0, viewport.height > 0 else { return }
        // Resizing calls this on every frame, so send only a new value. An empty value turns cropping off.
        let crop = fillVideo && !isPictureInPicture ? "\(Int(viewport.width.rounded())):\(Int(viewport.height.rounded()))" : ""
        if crop != sentCrop {
            sentCrop = crop
            send(.crop(crop.isEmpty ? nil : crop))
        }
        (videoView.superview as? SubtitleSurface)?.updateSubtitleLayout()
    }

    func stop() {
        saveProgress()
        seekFeedbackTask?.cancel()
        seekSeconds = nil
        addTask?.cancel()
        addTask = nil
        durationTask?.cancel()
        durationTask = nil
        endPictureInPicture()
        send(.stop)
        current = nil
        playlist = []
        playlistTitle = nil
        state = 0
        time = 0
        duration = 0
        seekable = false
        if let activity = sleepActivity { ProcessInfo.processInfo.endActivity(activity); sleepActivity = nil }
        updateNowPlaying()
    }
}

func timeLabel(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "0:00" }
    let value = Int(seconds)
    return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) : String(format: "%d:%02d", value / 60, value % 60)
}

func thumbnail(_ source: CGImageSource?, maxPixelSize: Int) -> CGImage? {
    source.flatMap {
        CGImageSourceCreateThumbnailAtIndex($0, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary)
    }
}
