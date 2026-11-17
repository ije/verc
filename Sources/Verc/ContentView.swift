import AppKit
import SwiftUI

struct ContentView: View {
  @Bindable var player: PlayerModel
  @Bindable var favorites: FavoritePages
  @Binding var showPlaylist: Bool
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var dropTargeted = false
  @State private var droppedURLs: [URL]?
  @State private var controlsVisible = true
  @State private var canvasHovered = false
  @State private var chromeHovered = false
  @State private var hideTask: Task<Void, Never>?
  @State private var trackedMenus: Set<ObjectIdentifier> = []
  @State private var scrubbing = false
  @State private var popup: PlayerPopup?
  @State private var playlistSelection: UUID?
  @FocusState private var playlistFocused: Bool
  @FocusState private var playbackPromptFocused: Bool

  private var playlistVisible: Bool { showPlaylist && player.playlist.count > 1 }
  private var modal: Bool {
    player.showInfo || player.showURL || player.showIconPicker || favorites.draft != nil
      || player.pendingPlayback != nil
  }
  private var hasAudioChoice: Bool {
    player.audioTracks.lazy.filter { $0.id != -1 }.prefix(2).count > 1
  }
  private var headerTitle: String {
    guard let current = player.current else {
      return favorites.showAllMedia ? "Library" : favorites.selectedPage?.displayTitle ?? ""
    }
    return (current.name ?? (current.url.isFileURL ? current.url.lastPathComponent : current.title))
      + (player.speed == 1 ? "" : " · \(player.speed.formatted())×")
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
      .background(
        WindowChrome(
          title: headerTitle.isEmpty ? "Verc" : headerTitle, controlsVisible: controlsVisible
        ).frame(width: 0, height: 0)
      )
      .ignoresSafeArea()
      .preferredColorScheme(.dark)
      .tint(.primary)
  }

  private var playerCanvas: some View {
    ZStack {
      if player.current == nil {
        StartPage(player: player, favorites: favorites)
          .id(favorites.url)
          .disabled(!favorites.ready)
          .allowsHitTesting(popup == nil)
      } else {
        stage
        VStack {
          LinearGradient(
            colors: [.black.opacity(0.65), .clear], startPoint: .top, endPoint: .bottom
          ).frame(height: 105)
          Spacer(minLength: 0)
          LinearGradient(
            colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom
          ).frame(height: 130)
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
      if player.current?.isImage == false && !player.isPictureInPicture && !player.isPlaying
        && !player.isLoading && player.state != .failed
      {
        let label = showPlaylist ? "Hide Playlist" : player.playLabel
        Button {
          if showPlaylist { showPlaylist = false } else { player.togglePlay() }
        } label: {
          Image(systemName: player.state == .ended ? "arrow.counterclockwise" : "play.fill")
            .font(.system(size: 52, weight: .semibold))
            .foregroundStyle(.white.opacity(0.9))
            .frame(width: 100, height: 100)
            .contentShape(Circle())
            .shadow(color: .black.opacity(0.3), radius: 12, y: 2)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .modifier(PlaylistMotion(distance: playlistVisible ? 296 : 0))
        .allowsHitTesting(popup == nil)
      }
      SeekFeedback(player: player)
        .modifier(PlaylistMotion(distance: playlistVisible ? 296 : 0))
    }
    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
    .clipped()
    .background(.black)
    .onGeometryChange(for: CGSize.self) {
      $0.size
    } action: {
      player.viewport = $0
    }
    .overlay { if player.current != nil { PlayerContextMenu(player: player) } }
  }

  private var interactiveCanvas: some View {
    canvas
      .onContinuousHover { phase in
        if case .active = phase {
          canvasHovered = true
        } else {
          canvasHovered = false
          chromeHovered = false
        }
        revealControls()
      }
      .onChange(
        of: player.isFullScreen && !controlsVisible && canvasHovered && scenePhase == .active
          && trackedMenus.isEmpty
      ) { _, hidden in
        NSCursor.setHiddenUntilMouseMoves(hidden)
      }
      .onChange(of: player.isPlaying) { revealControls() }
      .onChange(of: player.state) {
        guard player.state == .ended, player.repeatMode == .off, player.adjacentIndex(by: 1) == nil,
          let url = player.current?.url,
          let page = favorites.pages.first(where: { $0.media.contains(url) })
        else { return }
        favorites.select(page.id)
        player.stop()
      }
      .onChange(of: player.current?.id) {
        popup = nil
        revealControls()
        if let url = player.current?.url,
          let index = favorites.pages.firstIndex(where: { $0.media.contains(url) }), index > 0
        {
          favorites.pages.move(fromOffsets: IndexSet(integer: index), toOffset: 0)
        }
      }
      .onChange(of: popup) { revealControls() }
      .onChange(of: scenePhase) { if scenePhase != .active && popup != .credits { popup = nil } }
      .onChange(of: player.showURL) { revealControls() }
      .onChange(of: player.showInfo) { revealControls() }
      .onChange(of: player.showIconPicker) {
        popup = nil
        revealControls()
      }
      .onChange(of: player.pendingPlayback != nil) { revealControls() }
      .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification))
    { _ in player.isFullScreen = true }
      .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification))
    { _ in player.isFullScreen = false }
      .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) {
        notification in
        if let menu = notification.object as? NSMenu { trackedMenus.insert(ObjectIdentifier(menu)) }
        hideTask?.cancel()
      }
      .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) {
        notification in
        if let menu = notification.object as? NSMenu { trackedMenus.remove(ObjectIdentifier(menu)) }
        if trackedMenus.isEmpty { revealControls() }
      }
      .onDisappear {
        hideTask?.cancel()
        NSCursor.setHiddenUntilMouseMoves(false)
      }
  }

  private var dropCanvas: some View {
    interactiveCanvas
      .overlay {
        if dropTargeted {
          Group {
            if player.current == nil {
              RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                  .primary.opacity(0.48), style: StrokeStyle(lineWidth: 2, dash: [8, 5])
                )
                .padding(8)
                .ignoresSafeArea()
            } else {
              HStack(spacing: 12) {
                DropIcon()
                Text("Drop media")
              }
              .font(.title2.weight(.medium)).foregroundStyle(.white).padding(24)
              .glassEffect(
                .regular.tint(.black.opacity(0.35)), in: RoundedRectangle(cornerRadius: 12))
            }
          }
          .allowsHitTesting(false)
        }
      }
      .dropDestination(for: URL.self) { urls, _ in
        guard !urls.isEmpty else { return false }
        if favorites.open(urls, player: player) { return true }
        Task {
          let offerPlaylist = await Task.detached(priority: .userInitiated) { () -> Bool in
            let files = urls.filter {
              $0.isFileURL && !MediaItem.subtitleExtensions.contains($0.pathExtension.lowercased())
            }
            return files.count > 1
              || files.contains {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
              }
          }.value
          if offerPlaylist { droppedURLs = urls } else { player.add(urls) }
        }
        return true
      } isTargeted: {
        dropTargeted = $0
      }
  }

  var body: some View {
    dropCanvas
      .disabled(modal)
      .allowsHitTesting(!modal)
      .accessibilityHidden(modal)
      .overlay {
        if modal {
          ZStack {
            Color.black.opacity(0.18).ignoresSafeArea().accessibilityHidden(true)
              .onTapGesture {
                player.showIconPicker = false
                player.pendingPlayback = nil
              }
            if let request = player.pendingPlayback {
              VStack(alignment: .leading, spacing: 18) {
                Text(request.progress.finished ? "Play Again?" : "Resume Playback?")
                  .font(.title2.weight(.semibold))
                Text(
                  request.progress.finished
                    ? "Play “\(request.item.title)” from the start?"
                    : "Resume “\(request.item.title)” from \(timeLabel(min(request.progress.time, request.progress.duration))), or restart from the beginning?"
                )
                .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                HStack {
                  Spacer()
                  Button("Restart") {
                    player.pendingPlayback = nil
                    request.play(true)
                  }
                  .keyboardShortcut(request.progress.finished ? .defaultAction : nil)
                  if !request.progress.finished {
                    Button("Resume") {
                      player.pendingPlayback = nil
                      request.play(false)
                    }
                    .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                  }
                }
                .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.large)
              }
              .padding(24).frame(width: 360)
              .glassEffect(
                .regular.tint(.black.opacity(0.25)), in: RoundedRectangle(cornerRadius: 20)
              )
              .focusable().focused($playbackPromptFocused).focusEffectDisabled()
              .onAppear { playbackPromptFocused = true }
              .onExitCommand { player.pendingPlayback = nil }
              .accessibilityAddTraits(.isModal)
            } else if player.showIconPicker {
              IconPicker(isPresented: $player.showIconPicker)
            } else if let pages = favorites.draft {
              GeometryReader { geometry in
                let compact = geometry.size.height < 580
                FavoriteEditor(favorites: favorites, pages: pages, player: player, compact: compact)
                  .id(pages.first?.id).padding(compact ? 12 : 20)
                  .frame(width: geometry.size.width, height: geometry.size.height)
              }
              .ignoresSafeArea()
            } else if player.showURL {
              StreamDialog(player: player)
            } else {
              MediaInfo(player: player)
            }
          }
          .preferredColorScheme(.dark)
        }
      }
      .alert(
        "Unable to Complete Action",
        isPresented: Binding<Bool>(
          get: { player.error != nil || favorites.error != nil },
          set: {
            // Clear only the shown error, so the alert shows the other one next.
            if !$0 {
              if player.error != nil { player.error = nil } else { favorites.error = nil }
            }
          })
      ) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(player.error ?? favorites.error ?? "")
      }
      .alert(
        "Add to Library?",
        isPresented: Binding<Bool>(
          get: { droppedURLs != nil }, set: { if !$0 { droppedURLs = nil } }),
        presenting: droppedURLs
      ) { urls in
        Button("Add to Library…") { favorites.prepareDraft(urls, player: player) }
        Button("Open Now") { player.add(urls) }
        Button("Cancel", role: .cancel) {}
      } message: { _ in
        Text("Add these media files to your library, or open them now.")
      }
      .alert(
        "Remove from Library?",
        isPresented: Binding<Bool>(
          get: { favorites.pendingDeletion != nil },
          set: { if !$0 { favorites.pendingDeletion = nil } }),
        presenting: favorites.pendingDeletion
      ) { page in
        Button("Remove", role: .destructive) {
          favorites.remove(page)
          favorites.pendingDeletion = nil
          favorites.draft = nil
        }
        Button("Cancel", role: .cancel) { favorites.pendingDeletion = nil }
      } message: { page in
        Text("Remove “\(page.displayTitle)” from your library. Your media files will stay on disk.")
      }
  }

  private func revealControls() {
    hideTask?.cancel()
    controlsVisible = true
    guard player.isPlaying, !chromeHovered, !scrubbing, popup == nil, !showPlaylist,
      trackedMenus.isEmpty, !modal
    else { return }
    hideTask = Task {
      do { try await Task.sleep(for: .seconds(2.5)) } catch { return }
      withAnimation(.easeOut(duration: 0.2)) { controlsVisible = false }
    }
  }

  private var header: some View {
    Group {
      if player.current == nil, !favorites.showAllMedia, let page = favorites.selectedPage {
        Text("\(Text(page.title))\(Text(page.seasonSuffix).foregroundStyle(.gray))")
      } else {
        Text(headerTitle)
      }
    }
    .font(.system(size: 12, weight: .medium))
    .foregroundStyle(.white.opacity(0.8))
    .lineLimit(1).truncationMode(.middle)
    .padding(.horizontal, 126)
    .frame(maxWidth: .infinity).frame(height: 32)
    .contentShape(Rectangle())
    .gesture(WindowDragGesture())
    .overlay(alignment: .trailing) {
      if player.playlist.count > 1 && !showPlaylist
        && (player.current != nil || !favorites.showAllMedia)
      {
        IconButton(symbol: "list.triangle", label: "Show Playlist", help: "Show Playlist · ⌘L") {
          showPlaylist = true
        }
        .padding(.trailing, 12)
      } else if player.current == nil, !favorites.showAllMedia, let page = favorites.selectedPage {
        GlassIconButton(
          symbol: "info", label: page.editTitle, help: "\(page.editTitle)… · ⌘I", size: 18
        ) { favorites.draft = [page] }
        .keyboardShortcut("i")
        .padding(.trailing, 7)
      } else if player.current == nil && !favorites.showAllMedia && favorites.selection == nil {
        GlassIconButton(symbol: "info", label: "Credits", help: "Credits · ⌘I", size: 18) {
          popup = popup == .credits ? nil : .credits
        }
        .keyboardShortcut("i")
        .background {
          CreditsPopover(
            isPresented: Binding(
              get: { popup == .credits },
              set: {
                if $0 { popup = .credits } else if popup == .credits { popup = nil }
              }), content: creditsPopover.preferredColorScheme(.dark).fixedSize())
        }
        .padding(.trailing, 7)
      }
    }
    .onChange(of: player.playlist.count) { if player.playlist.count < 2 { showPlaylist = false } }
    .onChange(of: showPlaylist) {
      if showPlaylist { popup = nil }
      revealControls()
    }
    .onHover {
      chromeHovered = $0
      revealControls()
    }
  }

  private var playlistSidebar: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Label(player.playlistTitle ?? "Playlist", systemImage: "list.triangle")
          .font(.system(size: 13, weight: .semibold)).lineLimit(1)
          .help(player.playlistTitle ?? "Playlist")
        Text(player.playlist.count.formatted()).font(.system(size: 11)).foregroundStyle(.secondary)
          .padding(.horizontal, 6).frame(minWidth: 20, minHeight: 20)
          .background(.primary.opacity(0.08), in: Capsule())
          .overlay { Capsule().strokeBorder(.primary.opacity(0.15), lineWidth: 0.5) }
          .fixedSize()
        Spacer()
        Button {
          player.repeatMode =
            switch player.repeatMode {
            case .off: .all
            case .all: .one
            case .one: .off
            }
        } label: {
          Image(
            systemName: player.repeatMode == .all
              ? "repeat" : player.repeatMode == .one ? "repeat.1" : "repeat.badge.xmark"
          )
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(player.repeatMode == .off ? Color.secondary : .white)
          .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help("Repeat: \(player.repeatMode.rawValue)")
        .accessibilityLabel("Repeat").accessibilityValue(player.repeatMode.rawValue)
      }
      .padding(.horizontal, 16).padding(.vertical, 10)
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 4) {
            ForEach(player.playlist) { item in
              let playing = player.current?.id == item.id
              let selected = playlistSelection == item.id
              Button {
                playPlaylistItem(item)
              } label: {
                HStack(spacing: 12) {
                  if let artwork = item.artwork {
                    FavoriteArtwork(url: artwork, symbol: "film", symbolSize: 16, maxPixelSize: 160)
                      .frame(width: 56, height: 32)
                      .clipShape(RoundedRectangle(cornerRadius: 5))
                      .overlay {
                        if playing {
                          Image(systemName: "play.fill").font(.system(size: 12))
                            .foregroundStyle(.white).padding(6)
                            .background(.black.opacity(0.6), in: Circle())
                        }
                      }
                  } else {
                    Image(
                      systemName: playing
                        ? "play.fill"
                        : item.isImage ? "photo" : item.isAudio ? "music.note" : "film"
                    )
                    .font(.system(size: 16)).frame(width: 22)
                    .foregroundStyle(playing ? Color.white : .secondary)
                  }
                  VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.system(size: 12, weight: .medium))
                      .lineLimit(1).truncationMode(.tail)
                    PlaylistTime(player: player, duration: item.duration, selected: playing)
                  }
                  .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(
                  .primary.opacity(selected ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 10)
                )
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
        .onChange(of: playlistVisible) {
          if playlistVisible, let id = player.current?.id { proxy.scrollTo(id) }
        }
        .onChange(of: playlistSelection) {
          if playlistVisible, let id = playlistSelection { proxy.scrollTo(id) }
        }
      }
    }
    .frame(width: 280)
    .frame(maxHeight: .infinity)
    .glassEffect(
      .regular.tint(.black.opacity(0.25)),
      in: .rect(corners: .concentric(minimum: .fixed(8)), isUniform: true)
    )
    .focusable(playlistVisible).focused($playlistFocused).focusEffectDisabled()
    .onChange(of: playlistVisible) {
      playlistFocused = playlistVisible
      if playlistVisible { playlistSelection = player.current?.id }
    }
    .onChange(of: player.current?.id) {
      if !player.playlist.contains(where: { $0.id == playlistSelection }) {
        playlistSelection = player.current?.id
      }
    }
    .onKeyPress(keys: [.upArrow, .downArrow]) { press in
      guard playlistVisible,
        let index = player.playlist.firstIndex(where: { $0.id == playlistSelection })
      else { return .ignored }
      let next = min(max(index + (press.key == .upArrow ? -1 : 1), 0), player.playlist.count - 1)
      playlistSelection = player.playlist[next].id
      return .handled
    }
    .onKeyPress(.return) {
      guard playlistVisible, let item = player.playlist.first(where: { $0.id == playlistSelection })
      else { return .ignored }
      playPlaylistItem(item)
      return .handled
    }
    .onExitCommand { showPlaylist = false }
  }

  private func playPlaylistItem(_ item: MediaItem) {
    player.requestPlay(item) { restart in
      if restart || player.current?.id != item.id {
        player.play(item, restart: restart)
      } else if !player.isPlaying {
        player.togglePlay()
      }
      showPlaylist = false
    }
  }

  private var stage: some View {
    ZStack {
      Color.black
      VideoSurface(
        player: player, attached: !player.isPictureInPicture, controlsVisible: controlsVisible)
      if player.isPictureInPicture {
        VStack(spacing: 16) {
          Image(systemName: "pip").font(.system(size: 36, weight: .light))
          Text("Video is in Picture in Picture").font(.system(size: 14))
          Button("Exit Picture in Picture") { player.endPictureInPicture() }.buttonStyle(.plain)
        }.foregroundStyle(.white.opacity(0.7))
      } else if player.current?.isAudio == true
        || (!player.isLoading && player.videoWidth == 0 && !player.audioTracks.isEmpty)
      {
        VStack(spacing: 20) {
          Image(systemName: "waveform").font(.system(size: 60, weight: .ultraLight))
            .foregroundStyle(.white.opacity(0.6))
          Text(player.current?.title ?? "").font(.system(size: 24, weight: .medium))
            .foregroundStyle(.white).lineLimit(2)
        }
        .padding(40).offset(y: -65)
      }
      if player.isLoading { ProgressView().controlSize(.small).tint(.white) }
      if player.state == .failed {
        VStack(spacing: 12) {
          Image(systemName: "exclamationmark.triangle").font(.largeTitle)
          Text("Verc cannot play this media.").font(.headline)
          Button("Open Another File…") { player.openFiles() }.buttonStyle(.bordered)
        }.foregroundStyle(.white)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .clipped().contentShape(Rectangle())
    .onTapGesture(count: 2) {
      if showPlaylist { showPlaylist = false } else { NSApp.keyWindow?.toggleFullScreen(nil) }
    }
    .onTapGesture {
      if showPlaylist {
        showPlaylist = false
      } else {
        player.togglePlay()
        revealControls()
      }
    }
    .gesture(WindowDragGesture())
    .allowsHitTesting(popup == nil)
  }

  private var transport: some View {
    HStack(spacing: 12) {
      Button {
        popup = popup == .volume ? nil : .volume
      } label: {
        Image(
          systemName: player.muted || player.volume == 0
            ? "speaker.slash.fill" : "speaker.wave.2.fill"
        ).font(.system(size: 15)).frame(width: 28, height: 32)
      }
      .buttonStyle(.plain).help(player.muted ? "Volume · M to Unmute" : "Volume · M to Mute")
      .accessibilityLabel("Volume")
      .popover(
        isPresented: Binding(
          get: { popup == .volume },
          set: {
            if $0 { popup = .volume } else if popup == .volume { popup = nil }
          }), arrowEdge: .top
      ) {
        volumePopover.preferredColorScheme(.dark).fixedSize()
      }
      Button {
        popup = popup == .tracks ? nil : .tracks
      } label: {
        Image(systemName: "captions.bubble").font(.system(size: 16)).frame(width: 28, height: 32)
          .foregroundStyle(player.subtitleID == -1 ? .gray : .white.opacity(0.9))
      }
      .buttonStyle(.plain).help("Subtitles and Audio Tracks").accessibilityLabel(
        "Subtitles and Audio Tracks"
      )
      .popover(
        isPresented: Binding(
          get: { popup == .tracks },
          set: {
            if $0 { popup = .tracks } else if popup == .tracks { popup = nil }
          }), arrowEdge: .top
      ) {
        tracksPopover.preferredColorScheme(.dark).fixedSize()
      }
      Timeline(player: player, scrubbing: $scrubbing, editingChanged: revealControls)
      IconButton(
        symbol: player.isPictureInPicture ? "pip.exit" : "pip.enter",
        label: player.pictureInPictureLabel, active: player.isPictureInPicture
      ) { player.togglePictureInPicture() }
      .disabled(!player.canPictureInPicture)
      IconButton(
        symbol: player.isFullScreen
          ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
        label: player.isFullScreen ? "Exit Full Screen" : "Enter Full Screen",
        help: player.isFullScreen ? "Exit Full Screen · 🌐︎F" : "Enter Full Screen · 🌐︎F"
      ) { NSApp.keyWindow?.toggleFullScreen(nil) }
    }
    .font(.system(size: 11, weight: .medium, design: .monospaced)).monospacedDigit()
    .foregroundStyle(.white.opacity(0.9))
    .padding(.horizontal, 28).padding(.top, 20).padding(.bottom, 22)
    .frame(maxWidth: 1100)
    .contentShape(Rectangle())
    .onHover {
      chromeHovered = $0
      revealControls()
    }
  }

  private var volumePopover: some View {
    VStack(spacing: 12) {
      Text("\(Int(player.volume * 100))%").font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.white)
      VolumeSlider(value: $player.volume).frame(width: 32, height: 132)
      IconButton(
        symbol: player.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
        label: player.muted ? "Unmute" : "Mute", active: player.muted
      ) { player.muted.toggle() }
    }.padding(.vertical, 18).padding(.horizontal, 12)
  }

  private var creditsPopover: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("VLC").font(.system(size: 13, weight: .semibold))
      Text("Verc uses VLC by VideoLAN for media playback.")
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 6) {
        CreditLink(
          label: "videolan.org", destination: URL(string: "https://www.videolan.org/vlc/")!)
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
        GlassIconButton(symbol: "plus", label: "Add Subtitles", help: "Add Subtitles…") {
          popup = nil
          player.openFiles(subtitles: true)
        }
      }
      if !subtitles.isEmpty {
        HStack(spacing: 8) {
          Text("Track").frame(width: 64, alignment: .leading)
          Picker(
            "Subtitle Track",
            selection: Binding(
              get: { player.subtitleID }, set: { player.selectTrack($0, subtitles: true) })
          ) {
            Text("Off").tag(Int32(-1))
            ForEach(subtitles) { track in
              if track.isExternal {
                Text(
                  "\(track.name) \(Text("\(Image(systemName: "text.document"))\(track.format.map { " \($0.uppercased())" } ?? "")").foregroundStyle(.gray))"
                ).tag(track.id)
              } else {
                Text(track.name).tag(track.id)
              }
            }
          }
          .labelsHidden().buttonSizing(.flexible).frame(maxWidth: .infinity, alignment: .leading)
        }
        if player.subtitleID != -1 {
          HStack(spacing: 8) {
            Text("Font").frame(width: 64, alignment: .leading)
            SubtitleFontPicker(player: player)
          }
          HStack(spacing: 8) {
            Text("Font Size").frame(width: 64, alignment: .leading)
            SubtitleSlider(value: $player.subtitleFontSize, range: 16...100)
              .accessibilityLabel("Subtitle Font Size")
              .accessibilityValue("\(Int(player.subtitleFontSize)) points")
            Text("\(Int(player.subtitleFontSize)) pt")
              .monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
          }
          HStack(spacing: 8) {
            Text("Position").frame(width: 64, alignment: .leading)
            SubtitleSlider(value: $player.subtitleBottomInset, range: 0...420)
              .accessibilityLabel("Subtitle Distance from Bottom")
              .accessibilityValue("\(Int(player.subtitleBottomInset)) points from the bottom")
            Text("\(Int(player.subtitleBottomInset)) pt")
              .monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
          }
        }
      }
      if hasAudioChoice {
        Divider()
        Text("Audio").font(.system(size: 11)).foregroundStyle(.secondary)
        Picker(
          "Audio Track",
          selection: Binding(
            get: { player.audioID }, set: { player.selectTrack($0, subtitles: false) })
        ) {
          Text("Off").tag(Int32(-1))
          ForEach(player.audioTracks.filter { $0.id != -1 }) { Text($0.name).tag($0.id) }
        }
        .buttonSizing(.flexible).frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .font(.system(size: 12)).pickerStyle(.menu)
    .padding(22).frame(width: 280)
  }
}

struct SeekFeedback: View {
  let player: PlayerModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack {
      if let seconds = player.seekSeconds {
        let forward = seconds.sign == .plus
        let amount = abs(seconds)
        HStack(spacing: 8) {
          Image(systemName: forward ? "forward.fill" : "backward.fill")
            .keyframeAnimator(initialValue: 0.0, trigger: reduceMotion ? 0 : seconds) {
              content, offset in
              content.offset(x: offset)
            } keyframes: { _ in
              CubicKeyframe(forward ? 4 : -4, duration: 0.12)
              CubicKeyframe(0, duration: 0.18)
            }
          Text(amount < 60 ? "\(Int(amount))s" : timeLabel(amount))
            .monospacedDigit()
            .contentTransition(.numericText(value: amount))
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(height: 42)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: forward ? .trailing : .leading)
        .id(forward)
        .transition(.opacity.combined(with: .offset(x: forward ? -12 : 12)))
      }
    }
    .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: player.seekSeconds)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
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
    if slides { content.offset(x: distance) } else { content.padding(.trailing, distance) }
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

/// Reads only the font, so slider steps in the same popover do not rebuild the long list of font families.
private struct SubtitleFontPicker: View {
  @Bindable var player: PlayerModel

  var body: some View {
    Picker("Subtitle Font", selection: $player.subtitleFont) {
      ForEach(PlayerModel.subtitleFonts, id: \.self) { Text($0).tag($0) }
    }
    .labelsHidden().buttonSizing(.flexible).frame(maxWidth: .infinity, alignment: .leading)
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
      SeekSlider(
        value: Binding(
          get: {
            scrubbing ? scrubTime : player.duration > 0 ? min(player.time, player.duration) : 0
          },
          set: {
            scrubTime = $0
            if !scrubbing { player.seek(to: $0) }
          }), duration: max(player.duration, 1), enabled: player.seekable
      ) { editing in
        if editing { scrubTime = player.time }
        scrubbing = editing
        if !editing { player.seek(to: scrubTime) }
        editingChanged()
      }
      .frame(height: 16)
      Text(player.duration > 0 ? timeLabel(player.duration) : "—")
        .frame(minWidth: 44, alignment: .leading)
    }
  }
}

private enum PlayerPopup { case volume, tracks, credits }

private struct CreditsPopover<Content: View>: NSViewRepresentable {
  @Binding var isPresented: Bool
  let content: Content

  func makeCoordinator() -> Coordinator { Coordinator(isPresented: $isPresented) }
  func makeNSView(context: Context) -> NSView { NSView() }

  func updateNSView(_ view: NSView, context: Context) {
    let coordinator = context.coordinator
    coordinator.isPresented = $isPresented
    guard isPresented else {
      coordinator.close()
      return
    }
    let panel = coordinator.panel
    guard !panel.isVisible, let window = view.window, let screen = window.screen else { return }
    let anchor = window.convertToScreen(view.convert(view.bounds, to: nil))
    let size = NSHostingView(rootView: content).fittingSize
    let x = min(
      max(anchor.midX - size.width / 2, screen.visibleFrame.minX + 8),
      screen.visibleFrame.maxX - size.width - 8)
    let outline = ArrowOutline(arrowX: min(max(anchor.midX - x, 30), size.width - 30))
    let host = NSHostingView(
      rootView:
        content
        .foregroundStyle(.white)
        .padding(.top, 12)
        .glassEffect(.regular, in: outline)
        .preferredColorScheme(.dark))
    panel.contentView = host
    panel.initialFirstResponder = host
    panel.setFrame(
      NSRect(
        x: x, y: max(screen.visibleFrame.minY + 8, anchor.minY - size.height - 16),
        width: size.width, height: size.height + 12), display: true)
    window.addChildWindow(panel, ordered: .above)
    panel.makeKeyAndOrderFront(nil)
    coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [
      .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown,
    ]) { [weak coordinator, weak view] event in
      guard let coordinator else { return event }
      if event.type == .keyDown {
        guard event.keyCode == 53 else { return event }
        coordinator.isPresented.wrappedValue = false
        return nil
      }
      guard event.window !== coordinator.panel else { return event }
      coordinator.isPresented.wrappedValue = false
      if let view, event.window === view.window,
        view.bounds.contains(view.convert(event.locationInWindow, from: nil))
      {
        return nil
      }
      return event
    }
    coordinator.resizeObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didResizeNotification, object: window, queue: .main
    ) { [weak coordinator] _ in
      MainActor.assumeIsolated { coordinator?.isPresented.wrappedValue = false }
    }
  }

  static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.close() }

  @MainActor final class Coordinator: NSObject, NSWindowDelegate {
    var isPresented: Binding<Bool>
    let panel = CreditsPanel(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: true)
    var monitor: Any?
    var resizeObserver: Any?

    init(isPresented: Binding<Bool>) {
      self.isPresented = isPresented
      super.init()
      panel.title = "Credits"
      panel.isOpaque = false
      panel.backgroundColor = .clear
      panel.hasShadow = false
      panel.hidesOnDeactivate = true
      panel.level = .popUpMenu
      panel.collectionBehavior = [.transient, .fullScreenAuxiliary]
      panel.appearance = NSAppearance(named: .darkAqua)
      panel.delegate = self
    }

    func windowDidResignKey(_ notification: Notification) { isPresented.wrappedValue = false }

    func close() {
      // Every update of a hidden popover calls this, so skip the window work when nothing is shown.
      guard panel.isVisible || panel.contentView != nil || monitor != nil || resizeObserver != nil
      else { return }
      if let monitor {
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
      }
      if let resizeObserver {
        NotificationCenter.default.removeObserver(resizeObserver)
        self.resizeObserver = nil
      }
      if panel.isKeyWindow { panel.parent?.makeKey() }
      panel.parent?.removeChildWindow(panel)
      panel.orderOut(nil)
      panel.contentView = nil
    }
  }
}

private final class CreditsPanel: NSPanel {
  override var canBecomeKey: Bool { true }
}

struct ArrowOutline: Shape {
  var arrowX: CGFloat?
  var top = true
  var depth: CGFloat = 12
  var radius: CGFloat = 16

  func path(in rect: CGRect) -> Path {
    let x = rect.minX + (arrowX ?? rect.width / 2)
    let y = { (inset: CGFloat) in top ? rect.minY + inset : rect.maxY - inset }
    let width = depth * 7 / 6
    let tip = depth / 6
    let body = Path(
      roundedRect: CGRect(
        x: rect.minX, y: top ? rect.minY + depth : rect.minY, width: rect.width,
        height: rect.height - depth), cornerRadius: radius)
    let arrow = Path { path in
      path.move(to: CGPoint(x: x - width, y: y(depth * 4 / 3)))
      path.addLine(to: CGPoint(x: x - tip, y: y(tip)))
      path.addQuadCurve(to: CGPoint(x: x + tip, y: y(tip)), control: CGPoint(x: x, y: y(0)))
      path.addLine(to: CGPoint(x: x + width, y: y(depth * 4 / 3)))
      path.closeSubpath()
    }
    return body.union(arrow)
  }
}

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
      Image(systemName: symbol).font(
        .system(size: size / 2, weight: size < 24 ? .semibold : .regular)
      )
      .foregroundStyle(.white.opacity(0.9))
      .frame(width: size, height: size).contentShape(Circle())
    }
    .buttonStyle(.plain).glassEffect(.clear.interactive(), in: Circle())
    .overlay {
      Circle().strokeBorder(
        .linearGradient(
          colors: [.white.opacity(0.4), .white.opacity(0.04), .white.opacity(0.2)],
          startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.5
      )
      .allowsHitTesting(false)
    }
    .help(help ?? label).accessibilityLabel(label)
  }
}

struct IconButton: View {
  let symbol: String
  let label: String
  var help: String?
  var active = false
  let action: () -> Void
  @State private var hovered = false

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: 14, weight: .medium))
        .foregroundStyle(.white.opacity(hovered || active ? 1 : 0.9))
        .frame(width: 28, height: 32).contentShape(Rectangle())
    }.buttonStyle(.plain).onHover { hovered = $0 }.help(help ?? label).accessibilityLabel(label)
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
    guard attached else {
      host.player = nil
      host.subviews.forEach { $0.removeFromSuperview() }
      return
    }
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
    // UDP, RTP, and SRT addresses such as udp://@:1234 listen on a local port and have no host.
    guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
      let scheme = url.scheme?.lowercased(), MediaItem.streamSchemes.contains(scheme),
      url.host?.isEmpty == false || (["udp", "rtp", "srt"].contains(scheme) && url.port != nil)
    else { return nil }
    return url
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Open URL").font(.title2.weight(.semibold))
      TextField("https://example.com/video.mp4", text: $address).textFieldStyle(.roundedBorder)
        .focused($focused)
        .accessibilityLabel("Media URL")
      HStack {
        Spacer()
        Button("Cancel") { player.showURL = false }.buttonStyle(.glass).keyboardShortcut(
          .cancelAction)
        Button("Open") {
          if let url {
            player.add([url])
            player.showURL = false
          }
        }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction).disabled(url == nil)
      }
    }
    .padding(30).frame(width: 440)
    .glassEffect(.clear.tint(.black.opacity(0.25)), in: RoundedRectangle(cornerRadius: 20))
    .task {
      await Task.yield()
      focused = true
    }
    .onExitCommand { player.showURL = false }
    .accessibilityAddTraits(.isModal)
  }
}

struct MediaInfo: View {
  @Bindable var player: PlayerModel
  @FocusState private var focused: Bool

  var body: some View {
    let ratio = player.videoRatio
    return VStack(alignment: .leading, spacing: 20) {
      Text("Media Information").font(.title2.weight(.semibold))
      Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
        GridRow {
          Text("Name").foregroundStyle(.secondary)
          Text(player.current?.title ?? "No media").lineLimit(2)
        }
        GridRow {
          Text(player.current?.url.isFileURL == true ? "File Type" : "Source").foregroundStyle(
            .secondary)
          Text(player.current?.detail ?? "—")
        }
        GridRow {
          Text("Duration").foregroundStyle(.secondary)
          Text(player.duration > 0 ? timeLabel(player.duration) : "—")
        }
        GridRow {
          Text("Resolution").foregroundStyle(.secondary)
          Text(
            verbatim: player.videoWidth > 0 ? "\(player.videoWidth) × \(player.videoHeight)" : "—")
        }
        GridRow {
          Text("Aspect Ratio").foregroundStyle(.secondary)
          Text(verbatim: ratio.height > 0 ? "\(Int(ratio.width)):\(Int(ratio.height))" : "—")
        }
      }.font(.system(size: 12)).textSelection(.enabled)
      HStack {
        Spacer()
        Button("Done") { player.showInfo = false }.buttonStyle(.glass).keyboardShortcut(
          .defaultAction)
      }
    }
    .padding(28).frame(width: 430)
    .glassEffect(.clear.tint(.black.opacity(0.25)), in: RoundedRectangle(cornerRadius: 20))
    .focusable().focused($focused).focusEffectDisabled()
    .onAppear { focused = true }
    .onExitCommand { player.showInfo = false }
    .accessibilityAddTraits(.isModal)
  }
}
