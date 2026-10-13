import AppKit
import SwiftUI

@main
struct VercApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var showPlaylist = false

    var body: some Scene {
        Window("Verc", id: "player") {
            ContentView(player: delegate.player, showPlaylist: $showPlaylist)
                .frame(minWidth: 640, minHeight: 360)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1080, height: 608)
        .commands { PlayerCommands(player: delegate.player, showPlaylist: $showPlaylist) }

        Window("About Verc", id: "about") {
            VStack(spacing: 16) {
                LiquidPlayIcon()
                VStack(spacing: 4) {
                    Text("Verc").font(.title2.weight(.semibold))
                    if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                       let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
                        Text("Version \(version) (\(build))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                VStack(spacing: 6) {
                    Text("Engine: libVLC \(delegate.player.engineVersion ?? "unavailable")")
                    Text("License: GNU GPL v2.0")
                }.font(.system(size: 12))
                if let copyright = Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String {
                    Text(copyright).font(.caption).foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center).textSelection(.enabled)
            .frame(width: 300).padding(28)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commandsRemoved()
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let player = PlayerModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        let files = arguments.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
        if !files.isEmpty { player.add(files) }
    }

    func application(_ application: NSApplication, open urls: [URL]) { player.add(urls) }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if player.isPictureInPicture { player.endPictureInPicture(); return false }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let engine = player.engine else { return .terminateNow }
        player.stop()
        engine.shutdown { Task { @MainActor in NSApp.reply(toApplicationShouldTerminate: true) } }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !player.isPictureInPicture }
}

struct PlayerCommands: Commands {
    @Bindable var player: PlayerModel
    @Environment(\.openWindow) private var openWindow
    @Binding var showPlaylist: Bool

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Verc") { openWindow(id: "about") }
        }
        CommandGroup(replacing: .newItem) {
            Button("Open Media…") { player.openFiles() }.keyboardShortcut("o")
            Button("Open URL…") { player.showURL = true }.keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Add Subtitles…") { player.openFiles(subtitles: true) }
                .keyboardShortcut("s", modifiers: [.command, .shift]).disabled(player.current == nil)
        }
        CommandMenu("Playback") {
            Button(player.isPlaying ? "Pause" : "Play") { player.togglePlay() }.keyboardShortcut(.space, modifiers: [])
            Button("Stop") { player.stop() }.keyboardShortcut(".").disabled(player.current == nil)
            Divider()
            Button("Back 10 Seconds") { player.seek(to: player.time - 10, showFeedback: true) }.keyboardShortcut(.leftArrow, modifiers: []).disabled(!player.seekable)
            Button("Forward 10 Seconds") { player.seek(to: player.time + 10, showFeedback: true) }.keyboardShortcut(.rightArrow, modifiers: []).disabled(!player.seekable)
            Divider()
            Toggle("Mute", isOn: $player.muted).keyboardShortcut("m", modifiers: [])
            Button("Volume Up") { player.volume = min(1, player.volume + 0.05) }
                .keyboardShortcut(showPlaylist ? nil : KeyboardShortcut(.upArrow, modifiers: []))
            Button("Volume Down") { player.volume = max(0, player.volume - 0.05) }
                .keyboardShortcut(showPlaylist ? nil : KeyboardShortcut(.downArrow, modifiers: []))
            Divider()
            Toggle("Repeat", isOn: $player.repeatMedia)
        }
        CommandGroup(after: .toolbar) {
            Button("Show Playlist") { showPlaylist = true }.keyboardShortcut("l").disabled(player.playlist.count < 2)
            Toggle("Fill Window", isOn: $player.fillVideo)
            Button(player.isPictureInPicture ? "Exit Picture in Picture" : "Picture in Picture") { player.togglePictureInPicture() }
                .keyboardShortcut("p", modifiers: [.command, .shift]).disabled(!player.canPictureInPicture)
            Button("Media Information") { player.showInfo = true }.keyboardShortcut("i").disabled(player.current == nil)
        }
    }
}
