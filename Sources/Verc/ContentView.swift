import AppKit
import SwiftUI

enum Theme {
    static let muted = Color.primary.opacity(0.48)
}

struct ContentView: View {
    @Bindable var player: PlayerModel
    @Binding var showPlaylist: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dropTargeted = false
    @State private var controlsVisible = true
    @State private var chromeHovered = false
    @State private var hideTask: Task<Void, Never>?
    @State private var trackedMenus: Set<ObjectIdentifier> = []
    @State private var scrubbing = false
    @State private var popup: PlayerPopup?
    @State private var playlistSelection: UUID?
    @FocusState private var playlistFocused: Bool
    @State private var isFullScreen = false

    private var playlistVisible: Bool { showPlaylist && player.playlist.count > 1 }
    private var hasAudioChoice: Bool { player.audioTracks.lazy.filter { $0.id != -1 }.prefix(2).count > 1 }
    private var headerTitle: String {
        guard let current = player.current else { return "" }
        return (current.url.isFileURL ? current.url.lastPathComponent : current.title) + (player.speed == 1 ? "" : " · \(player.speed.formatted())×")
    }

    private var canvas: some View {
        playerCanvas
        .overlay(alignment: .trailing) {
            playlistSidebar
                .padding(8)
                .modifier(PlaylistMotion(distance: playlistVisible ? 0 : 296, slides: true))
                .disabled(!playlistVisible)
                .allowsHitTesting(playlistVisible)
                .accessibilityHidden(!playlistVisible)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: playlistVisible)
        .background(WindowChrome(title: headerTitle, controlsVisible: controlsVisible).frame(width: 0, height: 0))
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .tint(.primary)
    }

    private var playerCanvas: some View {
        ZStack {
            stage
            if player.current != nil {
                VStack {
                    LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .top, endPoint: .bottom).frame(height: 105)
                    Spacer(minLength: 0)
                    LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom).frame(height: 130)
                }
                .opacity(controlsVisible ? 1 : 0)
                .allowsHitTesting(false)
            }
            VStack(spacing: 0) {
                header
                Spacer(minLength: 0)
                if player.current != nil { transport }
            }
            .modifier(PlaylistMotion(distance: playlistVisible ? 296 : 0))
            .opacity(controlsVisible ? 1 : 0)
            .allowsHitTesting(controlsVisible)
            if player.current?.isImage == false && !player.isPictureInPicture && !player.isPlaying && !player.isLoading && player.state != 7 {
                Button {
                    if showPlaylist { showPlaylist = false }
                    else { player.togglePlay() }
                } label: {
                    Image(systemName: player.state == 6 ? "arrow.counterclockwise" : "play.fill")
                        .font(.system(size: 52, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 100, height: 100)
                        .contentShape(Circle())
                        .shadow(color: .black.opacity(0.3), radius: 12, y: 2)
                }
                .buttonStyle(.plain).accessibilityLabel(player.state == 6 ? "Replay" : "Play")
                .modifier(PlaylistMotion(distance: playlistVisible ? 296 : 0))
                .allowsHitTesting(popup == nil)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .background(.black)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { player.viewport = $0 }
        .overlay { PlayerContextMenu(player: player) }
    }

    private var interactiveCanvas: some View {
        canvas
        .onContinuousHover { phase in
            if case .ended = phase { chromeHovered = false }
            revealControls()
        }
        .onChange(of: player.isPlaying) { revealControls() }
        .onChange(of: player.current?.id) { popup = nil; revealControls() }
        .onChange(of: popup) { revealControls() }
        .onChange(of: scenePhase) { if scenePhase != .active { popup = nil } }
        .onChange(of: player.showURL) { revealControls() }
        .onChange(of: player.showInfo) { revealControls() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in isFullScreen = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in isFullScreen = false }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { notification in
            if let menu = notification.object as? NSMenu { trackedMenus.insert(ObjectIdentifier(menu)) }
            hideTask?.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { notification in
            if let menu = notification.object as? NSMenu { trackedMenus.remove(ObjectIdentifier(menu)) }
            if trackedMenus.isEmpty { revealControls() }
        }
        .onDisappear { hideTask?.cancel() }
        .overlay {
            if dropTargeted {
                Group {
                    if player.current == nil {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Theme.muted, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                            .padding(8)
                            .ignoresSafeArea()
                    } else {
                        HStack(spacing: 12) { DropIcon(); Text("Drop to play") }
                            .font(.title2.weight(.medium)).foregroundStyle(.white).padding(24)
                            .glassEffect(.regular.tint(.black.opacity(0.35)), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in player.add(urls); return !urls.isEmpty } isTargeted: { dropTargeted = $0 }
    }

    var body: some View {
        interactiveCanvas
        .disabled(player.showInfo || player.showURL)
        .allowsHitTesting(!player.showInfo && !player.showURL)
        .accessibilityHidden(player.showInfo || player.showURL)
        .overlay {
            if player.showInfo || player.showURL {
                ZStack {
                    Color.black.opacity(0.18).ignoresSafeArea().accessibilityHidden(true)
                    if player.showURL { StreamDialog(player: player) }
                    else { MediaInfo(player: player) }
                }
                .preferredColorScheme(.dark)
            }
        }
        .alert("Unable to complete action", isPresented: Binding<Bool>(get: { player.error != nil }, set: { if !$0 { player.error = nil } })) {
            Button("OK") { player.error = nil }
        } message: { Text(player.error ?? "") }
    }

    private func revealControls() {
        hideTask?.cancel()
        controlsVisible = true
        guard player.isPlaying, !chromeHovered, !scrubbing, popup == nil, !showPlaylist, trackedMenus.isEmpty, !player.showURL, !player.showInfo else { return }
        hideTask = Task {
            do { try await Task.sleep(for: .seconds(2.5)) } catch { return }
            withAnimation(.easeOut(duration: 0.2)) { controlsVisible = false }
        }
    }

    private var header: some View {
        Text(headerTitle)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white.opacity(0.8))
        .lineLimit(1).truncationMode(.middle)
        .padding(.horizontal, 126)
        .frame(maxWidth: .infinity).frame(height: 32)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
        .overlay(alignment: .trailing) {
            if player.playlist.count > 1 && !showPlaylist {
                IconButton(symbol: "list.triangle", label: "Show playlist") {
                    showPlaylist = true
                }
                .padding(.trailing, 12)
            } else if player.current == nil {
                GlassIconButton(symbol: "info", label: "About Verc", size: 18) {
                    popup = popup == .credits ? nil : .credits
                }
                .popover(isPresented: Binding(get: { popup == .credits }, set: {
                    if $0 { popup = .credits }
                    else if popup == .credits { popup = nil }
                }), arrowEdge: .bottom) {
                    creditsPopover.preferredColorScheme(.dark).fixedSize()
                }
                .padding(.trailing, 7)
            }
        }
        .onChange(of: player.playlist.count) { if player.playlist.count < 2 { showPlaylist = false } }
        .onChange(of: showPlaylist) {
            if showPlaylist { popup = nil }
            revealControls()
        }
        .onHover { chromeHovered = $0; revealControls() }
    }

    private var playlistSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Playlist", systemImage: "list.triangle").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(player.playlist.count.formatted()).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(16)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(player.playlist) { item in
                            let playing = player.current?.id == item.id
                            let selected = playlistSelection == item.id
                            Button {
                                if !playing { player.play(item) }
                                showPlaylist = false
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: playing ? "play.fill" : item.isImage ? "photo" : item.isAudio ? "music.note" : "film")
                                        .font(.system(size: 16)).frame(width: 22)
                                        .foregroundStyle(playing ? Color.white : .secondary)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.title).font(.system(size: 12, weight: .medium))
                                            .lineLimit(1).truncationMode(.tail)
                                        PlaylistTime(player: player, duration: item.duration, selected: playing)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(.primary.opacity(selected ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 10))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(item.url.isFileURL ? item.url.path : item.url.absoluteString)
                            .accessibilityAddTraits(selected ? [.isSelected] : [])
                            .id(item.id)
                        }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 8)
                }
                .onChange(of: playlistVisible) { if playlistVisible, let id = player.current?.id { proxy.scrollTo(id) } }
                .onChange(of: playlistSelection) { if playlistVisible, let id = playlistSelection { proxy.scrollTo(id) } }
            }
        }
        .frame(width: 280)
        .frame(maxHeight: .infinity)
        .glassEffect(.regular.tint(.black.opacity(0.25)), in: .rect(corners: .concentric(minimum: .fixed(8)), isUniform: true))
        .focusable(playlistVisible).focused($playlistFocused).focusEffectDisabled()
        .onChange(of: playlistVisible) {
            playlistFocused = playlistVisible
            if playlistVisible { playlistSelection = player.current?.id }
        }
        .onChange(of: player.current?.id) {
            if !player.playlist.contains(where: { $0.id == playlistSelection }) { playlistSelection = player.current?.id }
        }
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            guard playlistVisible,
                  let index = player.playlist.firstIndex(where: { $0.id == playlistSelection }) else { return .ignored }
            let next = min(max(index + (press.key == .upArrow ? -1 : 1), 0), player.playlist.count - 1)
            playlistSelection = player.playlist[next].id
            return .handled
        }
        .onKeyPress(.return) {
            guard playlistVisible, let item = player.playlist.first(where: { $0.id == playlistSelection }) else { return .ignored }
            if player.current?.id != item.id { player.play(item) }
            else if !player.isPlaying { player.togglePlay() }
            showPlaylist = false
            return .handled
        }
        .onExitCommand { showPlaylist = false }
    }

    private var stage: some View {
        ZStack {
            if player.current != nil {
                Color.black
                VideoSurface(player: player, attached: !player.isPictureInPicture, controlsVisible: controlsVisible)
                if player.isPictureInPicture {
                    VStack(spacing: 16) {
                        Image(systemName: "pip").font(.system(size: 36, weight: .light))
                        Text("Playing in Picture in Picture").font(.system(size: 14))
                        Button("Return to window") { player.endPictureInPicture() }.buttonStyle(.plain)
                    }.foregroundStyle(.white.opacity(0.7))
                } else if player.current?.isAudio == true || (!player.isLoading && player.videoWidth == 0 && !player.audioTracks.isEmpty) {
                    VStack(spacing: 20) {
                        Image(systemName: "waveform").font(.system(size: 60, weight: .ultraLight)).foregroundStyle(.white.opacity(0.6))
                        Text(player.current?.title ?? "").font(.system(size: 24, weight: .medium)).foregroundStyle(.white).lineLimit(2)
                    }
                    .padding(40).offset(y: -65)
                }
                if player.isLoading { ProgressView().controlSize(.small).tint(.white) }
                if player.state == 7 {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                        Text("Couldn’t play this media.").font(.headline)
                        Button("Open another file") { player.openFiles() }.buttonStyle(.bordered)
                    }.foregroundStyle(.white)
                }
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped().contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if showPlaylist { showPlaylist = false }
            else if player.current == nil { player.openFiles() }
            else { NSApp.keyWindow?.toggleFullScreen(nil) }
        }
        .onTapGesture {
            if showPlaylist { showPlaylist = false }
            else if player.current != nil { player.togglePlay(); revealControls() }
        }
        .gesture(WindowDragGesture())
        .allowsHitTesting(popup == nil)
    }

    private var emptyState: some View {
        PrismBackground()
        .ignoresSafeArea()
        .overlay(alignment: .bottom) {
            VStack(spacing: 20) {
                Text("Drop media here or double-click to open.").font(.system(size: 15)).foregroundStyle(.secondary)
                if let message = player.engineError {
                    Label(message, systemImage: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(.orange)
                }
            }
            .shadow(color: .black, radius: 3)
            .padding(40)
            .allowsHitTesting(false)
        }
    }

    private var transport: some View {
        HStack(spacing: 12) {
            Button { popup = popup == .volume ? nil : .volume } label: {
                Image(systemName: player.muted || player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.system(size: 15)).frame(width: 28, height: 32)
            }
            .buttonStyle(.plain).help("Volume · M to mute").accessibilityLabel("Volume settings")
            .popover(isPresented: Binding(get: { popup == .volume }, set: {
                if $0 { popup = .volume }
                else if popup == .volume { popup = nil }
            }), arrowEdge: .top) {
                volumePopover.preferredColorScheme(.dark).fixedSize()
            }
            Button { popup = popup == .tracks ? nil : .tracks } label: {
                Image(systemName: "captions.bubble").font(.system(size: 16)).frame(width: 28, height: 32)
                    .foregroundStyle(player.subtitleID == -1 ? .gray : .white.opacity(0.9))
            }
            .buttonStyle(.plain).help("Subtitles and audio tracks").accessibilityLabel("Subtitles and audio tracks")
            .popover(isPresented: Binding(get: { popup == .tracks }, set: {
                if $0 { popup = .tracks }
                else if popup == .tracks { popup = nil }
            }), arrowEdge: .top) {
                tracksPopover.preferredColorScheme(.dark).fixedSize()
            }
            Timeline(player: player, scrubbing: $scrubbing, editingChanged: revealControls)
            IconButton(symbol: player.isPictureInPicture ? "pip.exit" : "pip.enter", label: player.isPictureInPicture ? "Exit Picture in Picture" : "Picture in Picture", active: player.isPictureInPicture) { player.togglePictureInPicture() }
                .disabled(!player.canPictureInPicture)
            IconButton(symbol: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", label: isFullScreen ? "Exit full screen · ⌃⌘F" : "Full screen · ⌃⌘F") { NSApp.keyWindow?.toggleFullScreen(nil) }
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced)).monospacedDigit()
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 28).padding(.top, 20).padding(.bottom, 22)
        .frame(maxWidth: 1100)
        .contentShape(Rectangle())
        .onHover { chromeHovered = $0; revealControls() }
    }

    private var volumePopover: some View {
        VStack(spacing: 12) {
            Text("\(Int(player.volume * 100))%").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            VolumeSlider(value: $player.volume).frame(width: 32, height: 132)
            IconButton(symbol: player.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", label: "Mute", active: player.muted) { player.muted.toggle() }
        }.padding(.vertical, 18).padding(.horizontal, 12)
    }

    private var creditsPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("VLC").font(.system(size: 13, weight: .semibold))
            Text("Verc uses VLC by VideoLAN for media playback.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                CreditLink(label: "videolan.org", destination: URL(string: "https://www.videolan.org/vlc/")!)
                Text("·").foregroundStyle(.tertiary)
                Text("GPL / LGPL").foregroundStyle(.secondary)
            }
            Divider().padding(.vertical, 4)
            Text("Prism Shader").font(.system(size: 13, weight: .semibold))
            Text("The prism shader is borrowed from the vgpu.sh home page by Vercel.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                CreditLink(label: "vgpu.sh", destination: URL(string: "https://vgpu.sh")!)
                Text("·").foregroundStyle(.tertiary)
                Text("MIT License").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11))
        .padding(22).frame(width: 260, alignment: .leading)
    }

    private var tracksPopover: some View {
        let subtitles = player.subtitleTracks.filter { $0.id != -1 }
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text("Subtitles").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                GlassIconButton(symbol: "plus", label: "Add subtitles", help: "Add subtitles…") { popup = nil; player.openFiles(subtitles: true) }
            }
            if !subtitles.isEmpty {
                HStack(spacing: 8) {
                    Text("Track").frame(width: 64, alignment: .leading)
                    Picker("Track", selection: Binding(get: { player.subtitleID }, set: {
                        player.subtitleID = $0
                        player.send(.track($0, true))
                    })) {
                        Text("Off").tag(Int32(-1))
                        ForEach(subtitles) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                }
                if player.subtitleID != -1 {
                    HStack(spacing: 8) {
                        Text("Font size").frame(width: 64, alignment: .leading)
                        SubtitleSlider(value: $player.subtitleFontSize, range: 16...100)
                            .accessibilityLabel("Subtitle Font Size")
                            .accessibilityValue("\(Int(player.subtitleFontSize)) points")
                        Text("\(Int(player.subtitleFontSize)) pt")
                            .monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                    }
                    HStack(spacing: 8) {
                        Text("Y position").frame(width: 64, alignment: .leading)
                        SubtitleSlider(value: $player.subtitleBottomInset, range: 0...420)
                            .accessibilityLabel("Subtitle Y Position")
                            .accessibilityValue("\(Int(player.subtitleBottomInset)) points from the bottom")
                        Text("\(Int(player.subtitleBottomInset)) pt")
                            .monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                    }
                }
            }
            if hasAudioChoice {
                Divider()
                Text("Audio").font(.system(size: 11)).foregroundStyle(.secondary)
                Picker("Track", selection: Binding(get: { player.audioID }, set: {
                    player.audioID = $0
                    player.send(.track($0, false))
                })) {
                    Text("Off").tag(Int32(-1))
                    ForEach(player.audioTracks.filter { $0.id != -1 }) { Text($0.name).tag($0.id) }
                }
            }
        }
        .font(.system(size: 12)).pickerStyle(.menu)
        .padding(22).frame(width: 280)
    }
}

private nonisolated struct PlaylistMotion: AnimatableModifier {
    var distance: CGFloat
    var slides = false

    var animatableData: CGFloat {
        get { distance }
        set { distance = newValue }
    }

    func body(content: Content) -> some View {
        if slides { content.offset(x: distance) }
        else { content.padding(.trailing, distance) }
    }
}

private struct PlaylistTime: View {
    let player: PlayerModel
    let duration: Double?
    let selected: Bool

    var body: some View {
        Text((selected ? "\(timeLabel(player.time)) / " : "") + (duration.map(timeLabel) ?? "—"))
            .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
    }
}

/// Reads `player.time` on its own so position updates redraw only the timeline, not the whole player.
private struct Timeline: View {
    let player: PlayerModel
    @Binding var scrubbing: Bool
    let editingChanged: () -> Void
    @State private var scrubTime = 0.0

    var body: some View {
        HStack(spacing: 12) {
            Text(timeLabel(scrubbing ? scrubTime : player.time)).frame(minWidth: 38, alignment: .trailing)
            SeekSlider(value: Binding(get: { scrubbing ? scrubTime : min(player.time, max(player.duration, 1)) }, set: {
                scrubTime = $0
                if !scrubbing { player.seek(to: $0) }
            }), duration: max(player.duration, 1), enabled: player.seekable) { editing in
                if editing { scrubTime = player.time }
                scrubbing = editing
                if !editing { player.seek(to: scrubTime) }
                editingChanged()
            }
            .frame(height: 16)
            Text(player.duration > 0 ? timeLabel(player.duration) : "LIVE")
                .frame(minWidth: 44, alignment: .leading)
        }
    }
}

private enum PlayerPopup { case volume, tracks, credits }

private struct CreditLink: View {
    let label: String
    let destination: URL
    @State private var hovered = false

    var body: some View {
        Link(destination: destination) {
            Text(label).foregroundStyle(.secondary).underline(hovered)
        }.buttonStyle(.plain).onHover { hovered = $0 }
    }
}

private struct GlassIconButton: View {
    let symbol: String
    let label: String
    var help: String?
    var size: CGFloat = 24
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size / 2, weight: size < 24 ? .semibold : .regular))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: size, height: size).contentShape(Circle())
        }
        .buttonStyle(.plain).glassEffect(.clear.interactive(), in: Circle())
        .overlay {
            Circle().strokeBorder(.linearGradient(colors: [.white.opacity(0.4), .white.opacity(0.04), .white.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .help(help ?? label).accessibilityLabel(label)
    }
}

struct IconButton: View {
    let symbol: String
    let label: String
    var active = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(hovered || active ? 1 : 0.9))
                .frame(width: 28, height: 32).contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovered = $0 }.help(label).accessibilityLabel(label)
    }
}

struct VideoSurface: NSViewRepresentable {
    let player: PlayerModel
    var attached = true
    var controlsVisible = false
    func makeNSView(context: Context) -> SubtitleSurface {
        let host = SubtitleSurface()
        host.wantsLayer = true
        return host
    }
    func updateNSView(_ host: SubtitleSurface, context: Context) {
        guard attached else { host.player = nil; host.subviews.forEach { $0.removeFromSuperview() }; return }
        host.player = player
        host.controlsVisible = controlsVisible
        let view = player.videoView
        if view.superview !== host {
            host.subviews.forEach { $0.removeFromSuperview() }
            view.removeFromSuperview()
            view.frame = host.bounds
            view.autoresizingMask = [.width, .height]
            host.addSubview(view)
        }
        host.updateSubtitleLayout()
    }
}

struct WindowChrome: NSViewRepresentable {
    let title: String
    let controlsVisible: Bool
    func makeNSView(context: Context) -> CanvasWindowView { CanvasWindowView() }
    func updateNSView(_ view: CanvasWindowView, context: Context) {
        view.title = title
        view.controlsVisible = controlsVisible
        view.configure()
    }
}

final class CanvasWindowView: NSView {
    var title = ""
    var controlsVisible = true
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.backgroundColor = .black
        configure()
    }
    func configure() {
        guard let window else { return }
        if window.title != title { window.title = title }
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.alphaValue = controlsVisible ? 1 : 0
        }
    }
}

struct StreamDialog: View {
    @Bindable var player: PlayerModel
    @State private var address = ""
    @FocusState private var focused: Bool
    private var url: URL? {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              MediaItem.streamSchemes.contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Open stream").font(.system(size: 25, weight: .semibold)).tracking(-0.8)
            Text("Enter a direct media URL.").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("https://example.com/video.mp4", text: $address).textFieldStyle(.roundedBorder).focused($focused)
            HStack {
                Text("Verc does not save stream URLs.").font(.system(size: 10)).foregroundStyle(Theme.muted)
                Spacer()
                Button("Cancel") { player.showURL = false }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
                Button("Open") { if let url { player.add([url]); player.showURL = false } }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction).disabled(url == nil)
            }
        }
        .padding(30).frame(width: 440)
        .glassEffect(.clear.tint(.black.opacity(0.25)), in: RoundedRectangle(cornerRadius: 20))
        .task { await Task.yield(); focused = true }
        .onExitCommand { player.showURL = false }
        .accessibilityAddTraits(.isModal)
    }
}

struct MediaInfo: View {
    @Bindable var player: PlayerModel
    @FocusState private var focused: Bool
    var body: some View {
        let frameRatio: String = {
            var width = player.videoWidth
            var height = player.videoHeight
            guard width > 0, height > 0 else { return "—" }
            while height != 0 { (width, height) = (height, width % height) }
            return "\(player.videoWidth / width):\(player.videoHeight / width)"
        }()
        return VStack(alignment: .leading, spacing: 20) {
            Text("Media information").font(.title2.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                GridRow { Text("Name").foregroundStyle(.secondary); Text(player.current?.title ?? "No media").lineLimit(2) }
                GridRow { Text("Format").foregroundStyle(.secondary); Text(player.current?.detail ?? "—") }
                GridRow { Text("Duration").foregroundStyle(.secondary); Text(timeLabel(player.duration)) }
                GridRow { Text("Resolution").foregroundStyle(.secondary); Text(verbatim: player.videoWidth > 0 ? "\(player.videoWidth) × \(player.videoHeight)" : "—") }
                GridRow { Text("Frame ratio").foregroundStyle(.secondary); Text(frameRatio) }
            }.font(.system(size: 12)).textSelection(.enabled)
            HStack { Spacer(); Button("Done") { player.showInfo = false }.buttonStyle(.glass).keyboardShortcut(.defaultAction) }
        }
        .padding(28).frame(width: 430)
        .glassEffect(.clear.tint(.black.opacity(0.25)), in: RoundedRectangle(cornerRadius: 20))
        .focusable().focused($focused).focusEffectDisabled()
        .onAppear { focused = true }
        .onExitCommand { player.showInfo = false }
        .accessibilityAddTraits(.isModal)
    }
}
