import AppKit
import SwiftUI

@MainActor final class PictureInPicture: NSObject, NSWindowDelegate {
    let window: NSPanel
    let mainWindow: NSWindow?
    private weak var player: PlayerModel?

    init(player: PlayerModel, mainWindow: NSWindow?) {
        self.player = player
        self.mainWindow = mainWindow
        let ratio = CGFloat(max(player.videoWidth, 1)) / CGFloat(max(player.videoHeight, 1))
        let size = CGSize(width: min(400, 300 * ratio), height: min(300, 400 / ratio))
        let screen = mainWindow?.screen ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        window = NSPanel(contentRect: CGRect(x: bounds.maxX - size.width - 24, y: bounds.minY + 24, width: size.width, height: size.height),
                         styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        window.title = "Picture in Picture"
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentAspectRatio = size
        window.contentMinSize = CGSize(width: size.width * 0.6, height: size.height * 0.6)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.delegate = self
        let content = NSHostingView(rootView: PictureInPictureView(player: player))
        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.layer?.masksToBounds = true
        window.contentView = content
        window.orderFrontRegardless()
        mainWindow?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) { player?.endPictureInPicture() }
}

private struct PictureInPictureView: View {
    @Bindable var player: PlayerModel
    @State private var hovered = false

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
    }
}
