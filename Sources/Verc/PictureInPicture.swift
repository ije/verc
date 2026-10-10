import AppKit
import SwiftUI

@MainActor final class PictureInPicture: NSObject, NSWindowDelegate {
    let window: PictureInPicturePanel
    let mainWindow: NSWindow?
    private weak var player: PlayerModel?

    init(player: PlayerModel, mainWindow: NSWindow?) {
        self.player = player
        self.mainWindow = mainWindow
        let ratio = CGFloat(max(player.videoWidth, 1)) / CGFloat(max(player.videoHeight, 1))
        let size = CGSize(width: min(400, 300 * ratio), height: min(300, 400 / ratio))
        let screen = mainWindow?.screen ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        window = PictureInPicturePanel(contentRect: CGRect(x: bounds.maxX - size.width - 24, y: bounds.minY + 24, width: size.width, height: size.height),
                                       styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        window.title = "Picture in Picture"
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.contentAspectRatio = size
        window.contentMinSize = CGSize(width: size.width * 0.6, height: size.height * 0.6)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.delegate = self
        let content = NSHostingView(rootView: PictureInPictureView(player: player, snapToCorner: { [weak window] in window?.snapToCorner() }))
        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.layer?.masksToBounds = true
        window.contentView = content
        window.orderFrontRegardless()
        mainWindow?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) { player?.endPictureInPicture() }
    func windowDidEndLiveResize(_ notification: Notification) { window.snapToCorner() }
}

final class PictureInPicturePanel: NSPanel {
    private var lastScrollTime = -Double.infinity
    private var scrollDelta = CGVector.zero
    private var scrolled = false
    private var cornerFrame: CGRect?

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .scrollWheel else { super.sendEvent(event); return }
        guard event.momentumPhase.isEmpty, NSEvent.pressedMouseButtons == 0 else { return }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            scrollDelta = .zero
            scrolled = false
            return
        }
        if event.phase.contains(.began) || (event.phase.isEmpty && event.timestamp - lastScrollTime > 0.25) {
            scrollDelta = .zero
            scrolled = false
        }
        lastScrollTime = event.timestamp
        if event.hasPreciseScrollingDeltas || !event.phase.isEmpty {
            guard !scrolled else { return }
            scrollDelta.dx += event.scrollingDeltaX
            scrollDelta.dy += event.scrollingDeltaY
            guard max(abs(scrollDelta.dx), abs(scrollDelta.dy)) >= 24 else { return }
            scrolled = true
        } else {
            scrollDelta = CGVector(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY)
            guard scrollDelta != .zero else { return }
        }
        let direction = abs(scrollDelta.dy) >= abs(scrollDelta.dx)
            ? CGVector(dx: 0, dy: scrollDelta.dy) : CGVector(dx: scrollDelta.dx, dy: 0)
        snapToCorner(direction: direction)
    }

    func snapToCorner(direction: CGVector = .zero) {
        guard let screen = screen ?? NSScreen.main else { return }
        let bounds = screen.visibleFrame.insetBy(dx: 24, dy: 24)
        var target = frame
        if direction != .zero, let cornerFrame { target.origin = cornerFrame.origin }
        let scale = min(1, min(bounds.width / target.width, bounds.height / target.height))
        target.size.width *= scale
        target.size.height *= scale
        let right = direction.dx == 0 ? target.midX >= bounds.midX : direction.dx > 0
        let top = direction.dy == 0 ? target.midY >= bounds.midY : direction.dy < 0
        target.origin = NSPoint(x: right ? bounds.maxX - target.width : bounds.minX,
                                y: top ? bounds.maxY - target.height : bounds.minY)
        let previous = cornerFrame
        cornerFrame = target
        guard direction == .zero ? target != frame : target != previous else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(target, display: true)
        }
    }
}

private struct PictureInPictureView: View {
    @Bindable var player: PlayerModel
    let snapToCorner: () -> Void
    @State private var hovered = false
    @GestureState private var dragging = false

    var body: some View {
        VideoSurface(player: player, controlsVisible: hovered)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                ZStack {
                    LinearGradient(colors: [.black.opacity(0.4), .clear], startPoint: .top, endPoint: .bottom)
                    VStack {
                        HStack {
                            IconButton(symbol: "pip.exit", label: "Return to window") { player.endPictureInPicture() }
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(10)
                    if !player.isPlaying && player.current?.isImage == false {
                        Button { player.togglePlay() } label: {
                            Image(systemName: "play.fill")
                                .font(.system(size: 36, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.9))
                                .frame(width: 72, height: 72).contentShape(Circle())
                                .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
                        }
                        .buttonStyle(.plain)
                        .help("Play")
                        .accessibilityLabel("Play")
                    }
                }
                .opacity(hovered || !player.isPlaying ? 1 : 0)
                .allowsHitTesting(hovered || !player.isPlaying)
            }
            .background(.black).preferredColorScheme(.dark)
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .onTapGesture(count: 2) { player.endPictureInPicture() }
            .onTapGesture { player.togglePlay() }
            .gesture(WindowDragGesture().updating($dragging) { _, dragging, _ in dragging = true })
            .onChange(of: dragging) { if !dragging { snapToCorner() } }
            .allowsWindowActivationEvents()
    }
}
