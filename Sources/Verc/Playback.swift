import AppKit
import VLC
import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

struct MediaItem: Identifiable {
    let id = UUID()
    let url: URL
    var duration: Double?
    var subtitles: [URL] = []
    var title: String { url.isFileURL ? url.deletingPathExtension().lastPathComponent : ["", "/"].contains(url.lastPathComponent) ? url.host ?? "Stream" : url.lastPathComponent }
    var isAudio: Bool { Self.audioExtensions.contains(url.pathExtension.lowercased()) || UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) == true }
    var isImage: Bool { UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true }
    var detail: String { url.isFileURL ? url.pathExtension.uppercased() : "STREAM" }
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
}

struct MediaTrack: Identifiable, Equatable, Sendable {
    let id: Int32
    let name: String
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
    case open(URL, UUID), pause(Bool), seek(Double), volume(Double), rate(Float)
    case track(Int32, Bool), subtitle(URL), crop(String?), stop
    case subtitleLayout(width: Double, height: Double, bottomInset: Double, fontSize: Double, font: String)
}

final class VLC: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.verc.playback", qos: .userInitiated)
    private let metadataQueue = DispatchQueue(label: "app.verc.metadata", qos: .utility)
    private var handle: OpaquePointer?
    private var timer: DispatchSourceTimer?
    private var mediaID = UUID()
    private var closed = false
    private var externalSubtitles = false
    private var endTime: UInt64?
    var onUpdate: (@Sendable (PlaybackSnapshot) -> Void)?
    var onError: (@Sendable (String) -> Void)?

    /// Loads libVLC on the playback queue: it opens every bundled plugin, which would otherwise delay launch.
    init(view address: UInt, onStart: @escaping @Sendable (Result<String, any Error>) -> Void) {
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
        queue.async { [self] in
            guard !closed, let handle else { return }
            switch command {
            case let .open(url, id):
                mediaID = id
                externalSubtitles = false
                endTime = nil
                if vc_open(handle, url.absoluteString) != 0 { onError?("This media could not be opened. Check the file or stream address.") }
                if timer == nil {
                    let source = DispatchSource.makeTimerSource(queue: queue)
                    source.setEventHandler { [weak self] in self?.publish() }
                    source.activate()
                    timer = source
                }
                timer?.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(50))
            case let .pause(paused):
                vc_pause(handle, paused ? 1 : 0)
                timer?.schedule(deadline: .now(), repeating: .milliseconds(paused ? 1000 : 250), leeway: .milliseconds(50))
            case let .seek(seconds):
                endTime = nil
                vc_seek(handle, Int64(max(0, seconds) * 1000))
            case let .volume(volume): vc_volume(handle, Int32((volume * 100).rounded()))
            case let .rate(rate):
                if vc_rate(handle, rate) != 0 { onError?("This stream does not support changing playback speed.") }
            case let .track(id, subtitles):
                if vc_select_track(handle, subtitles ? 1 : 0, id) != 0 { onError?("The selected track is unavailable.") }
            case let .subtitle(url):
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
        var groups: [[MediaTrack]] = []
        for subtitles: Int32 in [0, 1] {
            let head = vc_tracks(handle, subtitles)
            var node = head
            var tracks: [MediaTrack] = []
            while let track = node?.pointee {
                tracks.append(MediaTrack(id: track.id, name: track.id == -1 ? "Off" : track.name.map { String(cString: $0) } ?? "Track \(track.id)"))
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
                guard !closed, let handle, mediaID == id, [3, 4].contains(vc_state(handle)) else {
                    continuation.resume(returning: nil)
                    return
                }
                let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
                defer { try? FileManager.default.removeItem(at: temporary) }
                do {
                    // VLC can return success even when encoding or writing the snapshot fails.
                    guard vc_snapshot(handle, temporary.path) == 0,
                          let source = CGImageSourceCreateWithURL(temporary as CFURL, nil),
                          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: 480
                          ] as CFDictionary) else {
                        throw NSError(domain: "Verc", code: 2, userInfo: [NSLocalizedDescriptionKey: "The current video frame could not be captured. Try again when the video is ready."])
                    }
                    try FileManager.default.moveItem(at: temporary, to: url)
                    continuation.resume(returning: image)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func duration(of url: URL) async -> Double? {
        await metadata(nil) { handle in
            let milliseconds = vc_read_duration(handle, url.absoluteString)
            return milliseconds > 0 ? Double(milliseconds) / 1000 : nil
        }
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

    private func metadata<T: Sendable>(_ fallback: T, _ body: @escaping @Sendable (OpaquePointer?) -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard !closed, handle != nil else { continuation.resume(returning: fallback); return }
                metadataQueue.async { [self] in continuation.resume(returning: body(handle)) }
            }
        }
    }

    func shutdown(_ completion: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            if !closed {
                closed = true
                timer?.cancel()
                timer = nil
            }
            metadataQueue.async { [self] in
                queue.async { [self] in
                    if let handle { vc_destroy(handle); self.handle = nil }
                    completion()
                }
            }
        }
    }
}

@MainActor @Observable final class PlayerModel {
    static let subtitleFonts = NSFontManager.shared.availableFontFamilies.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    var current: MediaItem?
    private(set) var playlist: [MediaItem] = []
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
        didSet { send(.rate(speed)) }
    }
    var repeatMode = RepeatMode.off
    var fillVideo = true { didSet { updateCrop() } }
    var viewport = CGSize.zero { didSet { updateCrop() } }
    var showURL = false
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
    var canPictureInPicture: Bool { isPictureInPicture || (current != nil && videoWidth > 0 && videoHeight > 0) }
    var canSaveFrame: Bool { current?.isAudio == false && videoWidth > 0 && videoHeight > 0 && (state == 3 || state == 4) && !isSavingFrame }
    var isPlaying: Bool { state == 3 }
    var isLoading: Bool { current != nil && (state == 0 || state == 1 || state == 2) }
    init() {
        if let font = UserDefaults.standard.string(forKey: "subtitleFont"), Self.subtitleFonts.contains(font) { subtitleFont = font }
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
    }

    private func engineStarted(_ result: Result<String, any Error>) {
        switch result {
        case let .success(version): engineVersion = version
        case let .failure(failure):
            engineError = failure.localizedDescription
            if current != nil { state = 7; error = engineError }
        }
    }

    private func receive(_ snapshot: PlaybackSnapshot) {
        guard current != nil, playbackID == snapshot.id else { return }
        let previous = state
        state = snapshot.state
        time = snapshot.time
        duration = snapshot.duration
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
            updateCrop()
            for url in current?.subtitles ?? [] { send(.subtitle(url)) }
        }
        if isPlaying && sleepActivity == nil {
            sleepActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleDisplaySleepDisabled], reason: "Playing media")
        } else if !isPlaying, let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }
        if state == 6 && previous != 6 {
            if repeatMode == .one { togglePlay() }
            else if let index = playlist.firstIndex(where: { $0.id == current?.id }) {
                if index + 1 < playlist.count { play(playlist[index + 1]) }
                else if repeatMode == .all, let first = playlist.first { play(first) }
            }
        } else if state == 7 && previous != 7 {
            error = "Verc could not play this media. The file may be damaged, or the stream may be unavailable."
        }
    }

    func send(_ command: PlaybackCommand) {
        engine?.send(command)
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

    func openFiles(subtitles: Bool = false) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = !subtitles
        panel.title = subtitles ? "Add subtitles" : "Open file"
        if subtitles { panel.allowedContentTypes = MediaItem.subtitleExtensions.compactMap { UTType(filenameExtension: $0) } }
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.add(panel.urls)
        }
    }

    func add(_ urls: [URL]) {
        let isSubtitle = { (url: URL) in MediaItem.subtitleExtensions.contains(url.pathExtension.lowercased()) }
        let subtitles = urls.filter(isSubtitle)
        let sources = urls.filter { !isSubtitle($0) }
        guard !sources.isEmpty else { attach(subtitles); return }
        addTask?.cancel()
        addTask = Task { [weak self, engine] in
            let resolved = await Self.resolve(sources, engine: engine, expanding: true)
            guard let self, !Task.isCancelled else { return }
            if let failure = resolved.failure { error = failure }
            let items = resolved.media.map { MediaItem(url: $0) }
            guard !items.isEmpty else { attach(subtitles); return }
            for item in items where item.url.isFileURL { NSDocumentController.shared.noteNewRecentDocumentURL(item.url) }
            durationTask?.cancel()
            playlist = items
            playlist[0].subtitles = subtitles
            play(playlist[0])
            durationTask = Task { [weak self, engine] in
                guard items.count > 1, let engine else { return }
                for (index, item) in items.enumerated() where item.url.isFileURL && !item.isImage {
                    guard !Task.isCancelled else { return }
                    let duration = await engine.duration(of: item.url)
                    guard !Task.isCancelled, let self else { return }
                    if let duration, playlist[index].duration == nil { playlist[index].duration = duration }
                }
            }
        }
    }

    @concurrent private nonisolated static func resolve(_ urls: [URL], engine: VLC?, expanding: Bool) async -> (media: [URL], failure: String?) {
        var media: [URL] = []
        var failure: String?
        for url in urls {
            let ext = url.pathExtension.lowercased()
            // Remote .m3u8 files are HLS streams, and reading them would only delay playback.
            let isPlaylist = expanding && MediaItem.playlistExtensions.contains(ext) && (url.isFileURL || ext != "m3u8")
            var directory: ObjCBool = false
            let exists = url.isFileURL && FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
            if exists && directory.boolValue {
                do {
                    let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
                        .filter { file in
                            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return false }
                            let ext = file.pathExtension.lowercased()
                            guard !MediaItem.subtitleExtensions.contains(ext) else { return false }
                            if MediaItem.audioExtensions.contains(ext) || MediaItem.videoExtensions.contains(ext) { return true }
                            let type = UTType(filenameExtension: ext)
                            return type?.conforms(to: .audio) == true || type?.conforms(to: .movie) == true
                        }
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
            } else { media.append(url) }
        }
        return (media, failure)
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

    func play(_ item: MediaItem) {
        seekFeedbackTask?.cancel()
        seekSeconds = nil
        if current?.id != item.id && item.isAudio { endPictureInPicture() }
        current = item
        playbackID = UUID()
        state = 1
        time = 0
        duration = 0
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
        engine.send(.open(item.url, playbackID))
    }

    func togglePlay() {
        guard let item = current else {
            openFiles()
            return
        }
        if state == 6 || state == 7 || state == 5 { play(item) }
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
        } else { send(.seek(time)) }
    }

    func seek(by offset: Double) {
        guard seekable else { return }
        // Snapshots can report the old position until VLC finishes a seek, so count from the pending target.
        let base = seekSeconds == nil ? time : seekTarget
        if seekSeconds?.sign != offset.sign { seekOrigin = base }
        seekTarget = max(0, min(base + offset, duration > 0 ? duration : base + offset))
        seek(to: seekTarget)
        // Keep the offset's sign even when the move is zero, so the feedback shows the pressed direction at the ends.
        seekSeconds = Double(signOf: offset, magnitudeOf: seekTarget - seekOrigin)
        seekFeedbackTask = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { seekSeconds = nil }
        }
    }

    private func updateCrop() {
        guard viewport.width > 0, viewport.height > 0 else { return }
        send(.crop(fillVideo && !isPictureInPicture ? "\(Int(viewport.width.rounded())):\(Int(viewport.height.rounded()))" : nil))
    }

    func stop() {
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
        state = 0
        time = 0
        duration = 0
        seekable = false
        if let activity = sleepActivity { ProcessInfo.processInfo.endActivity(activity); sleepActivity = nil }
    }
}

func timeLabel(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "0:00" }
    let value = Int(seconds)
    return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) : String(format: "%d:%02d", value / 60, value % 60)
}
