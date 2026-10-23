import AppKit
import SwiftUI

struct PlayerContextMenu: NSViewRepresentable {
    let player: PlayerModel

    func makeNSView(context: Context) -> PlayerMenuView { PlayerMenuView() }
    func updateNSView(_ view: PlayerMenuView, context: Context) { view.player = player }
}

final class PlayerMenuView: NSView {
    var player: PlayerModel?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent,
              event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) { rightMouseDown(with: event) }

    override func rightMouseDown(with event: NSEvent) {
        guard let player else { return }
        var items: [NSMenuItem] = [
            PlayerMenuItem("Open File…") { player.openFiles() },
            PlayerMenuItem("Open URL…") { player.showURL = true }
        ]
        if player.current != nil {
            let subtitles = player.subtitleTracks.filter { $0.id != -1 }
            var subtitleItems: [NSMenuItem] = [PlayerMenuItem("Add Subtitles…") { player.openFiles(subtitles: true) }]
            if !subtitles.isEmpty {
                subtitleItems += [
                    .separator(),
                    PlayerMenuItem("Off", checked: player.subtitleID == -1) {
                        player.subtitleID = -1
                        player.send(.track(-1, true))
                    }
                ] + subtitles.map { track in
                    PlayerMenuItem(track.name, checked: player.subtitleID == track.id) {
                        player.subtitleID = track.id
                        player.send(.track(track.id, true))
                    }
                }
            }
            items += [
                PlayerMenuItem("Subtitles", children: subtitleItems),
                .separator(),
                PlayerMenuItem(player.playLabel) { player.togglePlay() },
                PlayerMenuItem("Stop") { player.stop() }
            ]
            if player.playlist.count > 1, player.playlist.contains(where: { $0.id == player.current?.id }) {
                items += [
                    PlayerMenuItem("Previous Item", enabled: player.adjacentIndex(by: -1) != nil) { player.playAdjacent(by: -1) },
                    PlayerMenuItem("Next Item", enabled: player.adjacentIndex(by: 1) != nil) { player.playAdjacent(by: 1) }
                ]
            }
            items += [
                .separator(),
                PlayerMenuItem("Video Size", children: [
                    PlayerMenuItem("Fill Window", checked: player.fillVideo) { player.fillVideo = true },
                    PlayerMenuItem("Fit Entire Video", checked: !player.fillVideo) { player.fillVideo = false }
                ]),
                PlayerMenuItem("Playback Speed", children: [Float(0.5), 0.75, 1, 1.25, 1.5, 2].map { speed in
                    PlayerMenuItem("\(speed.formatted())×", checked: player.speed == speed) { player.speed = speed }
                }),
                PlayerMenuItem("Repeat", children: RepeatMode.allCases.map { mode in
                    PlayerMenuItem(mode.rawValue, checked: player.repeatMode == mode) { player.repeatMode = mode }
                }),
                .separator(),
                PlayerMenuItem("Save Current Frame", enabled: player.canSaveFrame) { player.saveFrame() },
                PlayerMenuItem(player.pictureInPictureLabel, enabled: player.canPictureInPicture) {
                    player.togglePictureInPicture()
                },
                PlayerMenuItem(window?.styleMask.contains(.fullScreen) == true ? "Exit Full Screen" : "Enter Full Screen") { [weak window] in window?.toggleFullScreen(nil) },
                .separator(),
                PlayerMenuItem("Media Information") { player.showInfo = true }
            ]
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        items.forEach { menu.addItem($0) }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

private final class PlayerMenuItem: NSMenuItem {
    let handler: (() -> Void)?

    init(_ title: String, checked: Bool? = nil, enabled: Bool = true, children: [NSMenuItem]? = nil, action: (() -> Void)? = nil) {
        handler = action
        super.init(title: title, action: action == nil ? nil : #selector(invoke), keyEquivalent: "")
        target = self
        isEnabled = enabled
        if let checked { state = checked ? .on : .off }
        if let children {
            let menu = NSMenu(title: title)
            menu.autoenablesItems = false
            children.forEach { menu.addItem($0) }
            submenu = menu
        }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { handler?() }
}
