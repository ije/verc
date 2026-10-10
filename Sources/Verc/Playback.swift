import AppKit
import CVLC
import Foundation
import Observation
import UniformTypeIdentifiers

struct MediaItem {
    let id = UUID()
    let url: URL
    var title: String { url.isFileURL ? url.deletingPathExtension().lastPathComponent : ["", "/"].contains(url.lastPathComponent) ? url.host ?? "Stream" : url.lastPathComponent }
    var isAudio: Bool { Self.audioExtensions.contains(url.pathExtension.lowercased()) }
    var isImage: Bool { UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true }
    var detail: String { url.isFileURL ? url.pathExtension.uppercased() : "STREAM" }
    static let audioExtensions: Set<String> = ["mp3", "flac", "wav", "m4a", "aac", "opus", "aiff", "aif", "wma", "alac"]
    static let subtitleExtensions: Set<String> = ["srt", "vtt", "ass", "ssa", "sub", "idx", "ttml"]
    static let streamSchemes: Set<String> = ["http", "https", "rtsp", "rtp", "udp", "srt"]
}

struct MediaTrack: Identifiable, Equatable, Sendable {
    let id: Int32
    let name: String
}

struct PlaybackSnapshot: Sendable {
    let id: UUID
    let state: Int32
    let time: Double
    let duration: Double
    let seekable: Bool
    let width: UInt32
    let height: UInt32
    let audio: [MediaTrack]
    let subtitles: [MediaTrack]
    let audioID: Int32
    let subtitleID: Int32
}

enum PlaybackCommand: Sendable {
    case open(URL, UUID), pause(Bool), seek(Double), volume(Double), rate(Float)
    case track(Int32, Bool), subtitle(URL), crop(String?), stop
    case subtitleLayout(width: Double, height: Double, bottomInset: Double, fontSize: Double)
}

final class VLC: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.verc.playback", qos: .userInitiated)
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
            case let .subtitleLayout(width, height, bottomInset, fontSize):
                vc_subtitle_layout(handle, VCSubtitleLayout(width: width, height: height, bottomInset: bottomInset, fontSize: fontSize))
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
        _ = vc_video_size(handle, &width, &height)
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
            width: width, height: height, audio: groups[0], subtitles: groups[1],
            audioID: vc_selected_track(handle, 0), subtitleID: vc_selected_track(handle, 1)
        ))
        if state == 6 || state == 7 { timer?.schedule(deadline: .distantFuture) }
    }

    func shutdown(_ completion: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            if !closed {
                closed = true
                timer?.cancel()
                timer = nil
                if let handle { vc_destroy(handle) }
            }
            completion()
        }
    }
}

@MainActor @Observable final class PlayerModel {
    var current: MediaItem?
    var state: Int32 = 0
    var time = 0.0
    var duration = 0.0
    var seekable = false
    var videoWidth: UInt32 = 0
    var videoHeight: UInt32 = 0
    var audioTracks: [MediaTrack] = []
    var subtitleTracks: [MediaTrack] = []
    var audioID: Int32 = -1
    var subtitleID: Int32 = -1
    var volume = 0.8 {
        didSet { send(.volume(muted ? 0 : volume)) }
    }
    var muted = false {
        didSet { send(.volume(muted ? 0 : volume)) }
    }
    var speed: Float = 1 {
        didSet { send(.rate(speed)) }
    }
    var repeatMedia = false
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
    @ObservationIgnored let videoView = NSView()
    @ObservationIgnored private(set) var engine: VLC?
    @ObservationIgnored private var sleepActivity: NSObjectProtocol?
    @ObservationIgnored private var externalSubtitles: [URL] = []
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var playbackID = UUID()
    @ObservationIgnored private var pictureInPicture: PictureInPicture?
    var canPictureInPicture: Bool { isPictureInPicture || (current != nil && videoWidth > 0 && videoHeight > 0) }
    var isPlaying: Bool { state == 3 }
    var isLoading: Bool { current != nil && (state == 0 || state == 1 || state == 2) }
    init() {
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
        seekable = snapshot.seekable
        videoWidth = snapshot.width
        videoHeight = snapshot.height
        if audioTracks != snapshot.audio { audioTracks = snapshot.audio }
        if subtitleTracks != snapshot.subtitles { subtitleTracks = snapshot.subtitles }
        audioID = snapshot.audioID
        subtitleID = snapshot.subtitleID
        if snapshot.state == 3 && !didStart {
            didStart = true
            send(.volume(muted ? 0 : volume))
            send(.rate(speed))
            updateCrop()
            for url in externalSubtitles { send(.subtitle(url)) }
        }
        if isPlaying && sleepActivity == nil {
            sleepActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleDisplaySleepDisabled], reason: "Playing media")
        } else if !isPlaying, let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }
        if state == 6 && previous != 6 && repeatMedia { togglePlay() }
        else if state == 7 && previous != 7 {
            error = "Verc could not play this media. The file may be damaged, or the stream may be unavailable."
        }
    }

    func send(_ command: PlaybackCommand) {
        engine?.send(command)
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
        panel.allowsMultipleSelection = subtitles
        panel.canChooseDirectories = false
        panel.title = subtitles ? "Add subtitles" : "Open media"
        if subtitles { panel.allowedContentTypes = MediaItem.subtitleExtensions.compactMap { UTType(filenameExtension: $0) } }
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.add(panel.urls)
        }
    }

    func add(_ urls: [URL]) {
        let subtitles = urls.filter { MediaItem.subtitleExtensions.contains($0.pathExtension.lowercased()) }
        let media = urls.lazy.filter { !MediaItem.subtitleExtensions.contains($0.pathExtension.lowercased()) }
        var first: MediaItem?
        for url in media.prefix(1) {
            guard url.isFileURL || MediaItem.streamSchemes.contains(url.scheme?.lowercased() ?? "") else {
                error = "Use a local file or an HTTP, HTTPS, RTSP, RTP, UDP, or SRT stream."
                continue
            }
            if url.isFileURL {
                var directory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), !directory.boolValue else {
                    error = "This file is unavailable. Open a media file from its current location."
                    continue
                }
            }
            first = MediaItem(url: url)
            if url.isFileURL { NSDocumentController.shared.noteNewRecentDocumentURL(url) }
        }
        if let first {
            play(first)
            externalSubtitles = subtitles
        } else if current != nil {
            for url in subtitles {
                if !externalSubtitles.contains(url) { externalSubtitles.append(url) }
                if didStart { send(.subtitle(url)) }
            }
        } else if !subtitles.isEmpty { error = "Open a video or audio file before adding subtitles." }
    }

    private func play(_ item: MediaItem) {
        if current?.id != item.id {
            endPictureInPicture()
            externalSubtitles = []
        }
        current = item
        playbackID = UUID()
        state = 1
        time = 0
        duration = 0
        seekable = false
        videoWidth = 0
        videoHeight = 0
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
        time = min(max(0, seconds), duration > 0 ? duration : seconds)
        send(.seek(time))
    }

    private func updateCrop() {
        guard viewport.width > 0, viewport.height > 0 else { return }
        send(.crop(fillVideo && !isPictureInPicture ? "\(Int(viewport.width.rounded())):\(Int(viewport.height.rounded()))" : nil))
    }

    func stop() {
        endPictureInPicture()
        send(.stop)
        current = nil
        externalSubtitles = []
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
