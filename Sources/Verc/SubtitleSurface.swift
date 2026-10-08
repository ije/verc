import AppKit

final class SubtitleSurface: NSView {
    weak var player: PlayerModel? {
        didSet { if player !== oldValue { lastSize = .zero } }
    }
    var controlsVisible = false
    private var lastSize = CGSize.zero
    private var lastInset: CGFloat = 0
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        updateSubtitleLayout()
    }

    func updateSubtitleLayout() {
        guard let player, player.videoView.superview === self else { return }
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        var rect = CGRect(origin: .zero, size: size)
        if window != nil, window === player.videoView.window, !player.videoView.bounds.isEmpty {
            rect = convert(player.videoView.bounds, from: player.videoView)
        }
        if player.videoWidth > 0, player.videoHeight > 0 {
            let aspect = player.fillVideo && !player.isPictureInPicture && player.viewport.height > 0
                ? player.viewport.width / player.viewport.height : CGFloat(player.videoWidth) / CGFloat(player.videoHeight)
            let width = min(rect.width, rect.height * aspect)
            let height = width / aspect
            rect = CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
        }
        let inset = controlsVisible && !player.isPictureInPicture ? max(20, 80 - (size.height - rect.maxY)) : 20
        if lastSize != rect.size || lastInset != inset {
            lastSize = rect.size
            lastInset = inset
            player.send(.subtitleLayout(width: rect.width, height: rect.height, bottomInset: inset))
        }
    }
}
