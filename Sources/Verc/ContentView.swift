import AppKit
import SwiftUI

enum Theme {
    static let muted = Color.primary.opacity(0.48)
    static let surface = Color(nsColor: .windowBackgroundColor)
}

struct ContentView: View {
    @Bindable var player: PlayerModel
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance") private var appearance = "System"
    @State private var dropTargeted = false
    @State private var controlsVisible = true
    @State private var chromeHovered = false
    @State private var hideTask: Task<Void, Never>?
    @State private var trackedMenus: Set<ObjectIdentifier> = []
    @State private var scrubbing = false
    @State private var popup: PlayerPopup?
    @FocusState private var popupFocused: Bool
    private var hasAudioChoice: Bool { player.audioTracks.lazy.filter { $0.id != -1 }.prefix(2).count > 1 }
    private var headerTitle: String {
        guard let current = player.current else { return "" }
        return (current.url.isFileURL ? current.url.lastPathComponent : current.title) + (player.speed == 1 ? "" : " · \(player.speed.formatted())×")
    }

    private var canvas: some View {
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
            .opacity(controlsVisible ? 1 : 0)
            .allowsHitTesting(controlsVisible)
            if player.current?.isImage == false && !player.isPictureInPicture && !player.isPlaying && !player.isLoading && player.state != 7 {
                Button { player.togglePlay() } label: {
                    Image(systemName: player.state == 6 ? "arrow.counterclockwise" : "play.fill")
                        .font(.system(size: 52, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 100, height: 100)
                        .contentShape(Circle())
                        .shadow(color: .black.opacity(0.3), radius: 12, y: 2)
                }
                .buttonStyle(.plain).accessibilityLabel(player.state == 6 ? "Replay" : "Play")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(player.current == nil ? Theme.surface : .black)
        .background(WindowChrome(title: headerTitle, controlsVisible: controlsVisible).frame(width: 0, height: 0))
        .overlayPreferenceValue(PopupAnchor.self) { anchors in
            GeometryReader { geometry in
                if let popup, let anchor = anchors[popup] {
                    let button = geometry[anchor]
                    let width: CGFloat = popup == .volume ? 56 : 280
                    let left = min(max(button.midX - width / 2, 12), geometry.size.width - width - 12)
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { self.popup = nil }
                        .accessibilityHidden(true)
                    Group {
                        if popup == .volume { volumePopover }
                        else { tracksPopover }
                    }
                    .padding(.bottom, 7)
                    .glassEffect(.regular.tint(.black.opacity(0.35)), in: PopupShape(arrowX: button.midX - left))
                    .preferredColorScheme(.dark)
                    .fixedSize()
                    .focusable().focused($popupFocused).focusEffectDisabled()
                    .onExitCommand { self.popup = nil }
                    .onAppear { popupFocused = true }
                    .frame(width: width)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(.leading, left)
                    .padding(.bottom, geometry.size.height - button.minY + 6)
                }
            }
            .allowsHitTesting(popup != nil)
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { player.viewport = $0 }
        .ignoresSafeArea()
        .preferredColorScheme(player.current != nil ? .dark : appearance == "Light" ? .light : appearance == "Dark" ? .dark : nil)
        .tint(.primary)
    }

    private var interactiveCanvas: some View {
        canvas
        .overlay { PlayerContextMenu(player: player) }
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
        .disabled(player.showInfo)
        .allowsHitTesting(!player.showInfo)
        .accessibilityHidden(player.showInfo)
        .overlay {
            if player.showInfo {
                ZStack {
                    Color.black.opacity(0.18).ignoresSafeArea().accessibilityHidden(true)
                    MediaInfo(player: player)
                }
                .preferredColorScheme(.dark)
            }
        }
        .sheet(isPresented: $player.showURL) { StreamSheet(player: player) }
        .alert("Unable to complete action", isPresented: Binding<Bool>(get: { player.error != nil }, set: { if !$0 { player.error = nil } })) {
            Button("OK") { player.error = nil }
        } message: { Text(player.error ?? "") }
    }

    private func revealControls() {
        hideTask?.cancel()
        controlsVisible = true
        guard player.isPlaying, !chromeHovered, !scrubbing, popup == nil, trackedMenus.isEmpty, !player.showURL, !player.showInfo else { return }
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
        .onHover { chromeHovered = $0; revealControls() }
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
            if player.current == nil { player.openFiles() }
            else { NSApp.keyWindow?.toggleFullScreen(nil) }
        }
        .onTapGesture { if player.current != nil { player.togglePlay(); revealControls() } }
        .gesture(WindowDragGesture())
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            DropIcon().foregroundStyle(.primary).opacity(0.48).padding(.bottom, 12)
            Text("Drop media here or double-click to open.").font(.system(size: 14)).foregroundStyle(.gray)
            if let message = player.engineError {
                Label(message, systemImage: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(.orange).padding(.top, 20)
            }
        }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transport: some View {
        HStack(spacing: 12) {
            Button { popup = popup == .volume ? nil : .volume } label: {
                Image(systemName: player.muted || player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.system(size: 15)).frame(width: 28, height: 32)
            }
            .buttonStyle(.plain).help("Volume · M to mute").accessibilityLabel("Volume settings")
            .anchorPreference(key: PopupAnchor.self, value: .bounds) { [.volume: $0] }
            Button { popup = popup == .tracks ? nil : .tracks } label: {
                Image(systemName: "captions.bubble").font(.system(size: 16)).frame(width: 28, height: 32)
                    .foregroundStyle(player.subtitleID == -1 ? .gray : .white.opacity(0.9))
            }
            .buttonStyle(.plain).help("Subtitles and audio tracks").accessibilityLabel("Subtitles and audio tracks")
            .anchorPreference(key: PopupAnchor.self, value: .bounds) { [.tracks: $0] }
            Timeline(player: player, scrubbing: $scrubbing, editingChanged: revealControls)
            IconButton(symbol: player.isPictureInPicture ? "pip.exit" : "pip.enter", label: player.isPictureInPicture ? "Exit Picture in Picture" : "Picture in Picture", active: player.isPictureInPicture) { player.togglePictureInPicture() }
                .disabled(!player.canPictureInPicture)
            IconButton(symbol: "arrow.up.left.and.arrow.down.right", label: "Full screen · ⌃⌘F") { NSApp.keyWindow?.toggleFullScreen(nil) }
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

    private var tracksPopover: some View {
        let subtitles = player.subtitleTracks.filter { $0.id != -1 }
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text("Subtitles")
                Spacer(minLength: 0)
                Button { popup = nil; player.openFiles(subtitles: true) } label: {
                    Image(systemName: "plus").font(.system(size: 12))
                        .frame(width: 24, height: 24).contentShape(Circle())
                }
                .buttonStyle(.plain).glassEffect(.regular.interactive(), in: Circle())
                .help("Add subtitles…").accessibilityLabel("Add subtitles")
            }
            if !subtitles.isEmpty {
                HStack(spacing: 10) {
                    Text("Track")
                    Spacer(minLength: 0)
                    Picker("Track", selection: Binding(get: { player.subtitleID }, set: {
                        player.subtitleID = $0
                        player.send(.track($0, true))
                    })) {
                        Text("Off").tag(Int32(-1))
                        ForEach(subtitles) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
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

private enum PlayerPopup { case volume, tracks }

private struct PopupAnchor: PreferenceKey {
    static let defaultValue: [PlayerPopup: Anchor<CGRect>] = [:]
    static func reduce(value: inout [PlayerPopup: Anchor<CGRect>], nextValue: () -> [PlayerPopup: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct PopupShape: Shape {
    var arrowX: CGFloat

    func path(in rect: CGRect) -> Path {
        let bottom = rect.maxY - 7
        let body = Path(roundedRect: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - 7), cornerRadius: 10)
        var arrow = Path()
        arrow.move(to: CGPoint(x: arrowX - 9, y: bottom - 1))
        arrow.addLine(to: CGPoint(x: arrowX - 1, y: bottom + 6))
        arrow.addQuadCurve(to: CGPoint(x: arrowX + 1, y: bottom + 6), control: CGPoint(x: arrowX, y: bottom + 7))
        arrow.addLine(to: CGPoint(x: arrowX + 9, y: bottom - 1))
        arrow.closeSubpath()
        return body.union(arrow)
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
                .foregroundStyle(Color.primary.opacity(hovered || active ? 1 : 0.8))
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

struct StreamSheet: View {
    @Bindable var player: PlayerModel
    @Environment(\.dismiss) private var dismiss
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
            Image(systemName: "link").font(.system(size: 24, weight: .light))
            Text("Open stream").font(.system(size: 25, weight: .semibold)).tracking(-0.8)
            Text("Enter a direct media URL.").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("https://example.com/video.mp4", text: $address).textFieldStyle(.roundedBorder).focused($focused)
            HStack {
                Text("Verc does not save stream URLs.").font(.system(size: 10)).foregroundStyle(Theme.muted)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Open") { if let url { player.add([url]); dismiss() } }.keyboardShortcut(.defaultAction).disabled(url == nil)
            }
        }.padding(30).frame(width: 440).onAppear { focused = true }
    }
}

struct MediaInfo: View {
    @Bindable var player: PlayerModel
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Media information").font(.title2.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                GridRow { Text("Name").foregroundStyle(.secondary); Text(player.current?.title ?? "No media").lineLimit(2) }
                GridRow { Text("Format").foregroundStyle(.secondary); Text(player.current?.detail ?? "—") }
                GridRow { Text("Duration").foregroundStyle(.secondary); Text(timeLabel(player.duration)) }
                GridRow { Text("Resolution").foregroundStyle(.secondary); Text(player.videoWidth > 0 ? "\(player.videoWidth) × \(player.videoHeight)" : "—") }
                GridRow { Text("Engine").foregroundStyle(.secondary); Text("libVLC \(player.engineVersion ?? "unavailable")") }
                GridRow { Text("License").foregroundStyle(.secondary); Text("GNU GPL v2.0") }
            }.font(.system(size: 12)).textSelection(.enabled)
            HStack { Spacer(); Button("Done") { player.showInfo = false }.keyboardShortcut(.defaultAction) }
        }
        .padding(28).frame(width: 430)
        .glassEffect(.clear.tint(.black.opacity(0.25)), in: RoundedRectangle(cornerRadius: 20))
        .focusable().focused($focused).focusEffectDisabled()
        .onAppear { focused = true }
        .onExitCommand { player.showInfo = false }
        .accessibilityAddTraits(.isModal)
    }
}
