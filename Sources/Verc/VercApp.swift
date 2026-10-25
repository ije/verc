import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct VercApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var showPlaylist = false

    var body: some Scene {
        Window("Verc", id: "player") {
            ContentView(player: delegate.player, favorites: delegate.favorites, showPlaylist: $showPlaylist)
                .frame(minWidth: 640, minHeight: 360)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1080, height: 608)
        .commands { PlayerCommands(player: delegate.player, favorites: delegate.favorites, showPlaylist: $showPlaylist) }

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
    let favorites = FavoritePages()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        (AppIcon(rawValue: UserDefaults.standard.string(forKey: "appIcon") ?? "") ?? .glass).apply()
        NSApp.activate(ignoringOtherApps: true)
        player.openLibrary = { [weak self] urls in
            guard let self else { return false }
            return favorites.open(urls, player: player)
        }
        let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        let files = arguments.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
        if !files.isEmpty, !favorites.open(files, player: player) { player.add(files) }
        if !favorites.opening && !favorites.ready {
            let url = Library.url
            favorites.load(url, create: UserDefaults.standard.string(forKey: "libraryPath") == nil && url == Library.defaultURL
                && !FileManager.default.fileExists(atPath: url.path))
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if !favorites.open(urls, player: player) { player.add(urls) }
    }

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
    let favorites: FavoritePages
    @Environment(\.openWindow) private var openWindow
    @Binding var showPlaylist: Bool

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Verc") { openWindow(id: "about") }
        }
        CommandGroup(replacing: .appSettings) {
            Button("App Icon…") {
                openWindow(id: "player")
                player.showIconPicker.toggle()
            }.keyboardShortcut(",")
        }
        CommandGroup(replacing: .newItem) {
            Button("Open File…") { player.openFiles() }.keyboardShortcut("o")
            Button("Open URL…") { player.showURL = true }.keyboardShortcut("o", modifiers: [.command, .shift])
            Divider()
            Button("Create Library…") {
                let panel = NSSavePanel()
                panel.title = "Create Library"
                panel.prompt = "Create"
                panel.nameFieldStringValue = "Verc.verclibrary"
                panel.allowedContentTypes = [UTType(exportedAs: "me.jex.verc.library", conformingTo: .package)]
                panel.directoryURL = favorites.url?.deletingLastPathComponent() ?? Library.defaultURL.deletingLastPathComponent()
                panel.begin { response in
                    guard response == .OK, let url = panel.url else { return }
                    openWindow(id: "player")
                    favorites.open([url], player: player, create: true)
                }
            }
            .disabled(favorites.opening || favorites.saving || favorites.draft != nil)
            Button("Open Library…") {
                let panel = NSOpenPanel()
                panel.title = "Open Library"
                panel.allowedContentTypes = [UTType(exportedAs: "me.jex.verc.library", conformingTo: .package)]
                panel.directoryURL = favorites.url?.deletingLastPathComponent() ?? Library.defaultURL.deletingLastPathComponent()
                panel.begin { response in
                    guard response == .OK else { return }
                    openWindow(id: "player")
                    favorites.open(panel.urls, player: player)
                }
            }
            .disabled(favorites.opening || favorites.saving || favorites.draft != nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save Current Frame") { player.saveFrame() }.keyboardShortcut("s").disabled(!player.canSaveFrame)
        }
        CommandMenu("Subtitles") {
            let subtitles = player.subtitleTracks.filter { $0.id != -1 }
            Button("Add Subtitles…") { player.openFiles(subtitles: true) }
                .keyboardShortcut("s", modifiers: [.command, .shift]).disabled(player.current == nil)
            if player.current != nil && !subtitles.isEmpty {
                Divider()
                Picker("Track", selection: Binding(get: { player.subtitleID }, set: {
                    player.subtitleID = $0
                    player.send(.track($0, true))
                })) {
                    Text("Off").tag(Int32(-1))
                    ForEach(subtitles) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.inline)
            }
        }
        CommandMenu("Playback") {
            // Menu key equivalents run before text fields get the key, so turn off single keys while one is shown.
            let typing = player.showURL || player.showIconPicker || favorites.draft != nil || favorites.showAllMedia && player.current == nil
            Button(player.playLabel) { player.togglePlay() }
                .keyboardShortcut(typing ? nil : KeyboardShortcut(.space, modifiers: []))
            Button("Stop") { player.stop() }.keyboardShortcut(".").disabled(player.current == nil)
            Divider()
            Button("Skip Backward 10 Seconds") { player.seek(by: -10) }
                .keyboardShortcut(typing || player.current == nil ? nil : KeyboardShortcut(.leftArrow, modifiers: [])).disabled(!player.seekable)
            Button("Skip Forward 10 Seconds") { player.seek(by: 10) }
                .keyboardShortcut(typing || player.current == nil ? nil : KeyboardShortcut(.rightArrow, modifiers: [])).disabled(!player.seekable)
            Divider()
            Toggle("Mute", isOn: $player.muted)
                .keyboardShortcut(typing ? nil : KeyboardShortcut("m", modifiers: []))
            Button("Volume Up") { player.volume = min(1, player.volume + 0.05) }
                .keyboardShortcut(showPlaylist || typing ? nil : KeyboardShortcut(.upArrow, modifiers: []))
            Button("Volume Down") { player.volume = max(0, player.volume - 0.05) }
                .keyboardShortcut(showPlaylist || typing ? nil : KeyboardShortcut(.downArrow, modifiers: []))
            Divider()
            Picker("Repeat", selection: $player.repeatMode) {
                ForEach(RepeatMode.allCases, id: \.self) { mode in Text(mode.rawValue).tag(mode) }
            }
        }
        CommandGroup(after: .toolbar) {
            let browsing = favorites.ready && player.current == nil && !player.showURL && !player.showInfo && !player.showIconPicker && favorites.draft == nil
                && favorites.pendingDeletion == nil && !favorites.showAllMedia
            Button("Previous Preview") { favorites.movePreview(by: -1) }
                .keyboardShortcut(browsing ? KeyboardShortcut(.leftArrow, modifiers: []) : nil)
                .disabled(!browsing || favorites.selection == nil)
            Button("Next Preview") { favorites.movePreview(by: 1) }
                .keyboardShortcut(browsing ? KeyboardShortcut(.rightArrow, modifiers: []) : nil)
                .disabled(!browsing || favorites.selection == nil)
            Button("Previous Page") { favorites.movePage(by: -1) }
                .keyboardShortcut(browsing ? KeyboardShortcut(.leftArrow) : nil)
                .disabled(!browsing || favorites.pages.isEmpty)
            Button("Next Page") { favorites.movePage(by: 1) }
                .keyboardShortcut(browsing ? KeyboardShortcut(.rightArrow) : nil)
                .disabled(!browsing || favorites.pages.isEmpty)
            Divider()
            Button("Show Playlist") { showPlaylist = true }.keyboardShortcut("l").disabled(player.playlist.count < 2)
            Toggle("Fill Window", isOn: $player.fillVideo)
            Button(player.pictureInPictureLabel) { player.togglePictureInPicture() }
                .keyboardShortcut("p", modifiers: [.command, .shift]).disabled(!player.canPictureInPicture)
            Button("Media Information") { player.showInfo = true }
                .keyboardShortcut(player.current == nil ? nil : KeyboardShortcut("i")).disabled(player.current == nil)
        }
    }
}
