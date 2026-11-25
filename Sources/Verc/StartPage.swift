import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import simd

@MainActor private let tmdbLogo = Bundle.main.url(forResource: "TMDB", withExtension: "svg").flatMap
{ NSImage(contentsOf: $0) }

struct StartPage: View {
  let player: PlayerModel
  let favorites: FavoritePages
  let updateDriver: UpdateDriver?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  // Trails favorites.selection by one update. A removed page keeps the transition from its last render,
  // so it must render the new direction before it leaves.
  @State private var shown: UUID?
  @State private var tooltip: UUID?
  @State private var sortingDots = false
  @State private var libraryHovered = false
  @State private var addHovered = false

  init(player: PlayerModel, favorites: FavoritePages, updateDriver: UpdateDriver?) {
    self.player = player
    self.favorites = favorites
    self.updateDriver = updateDriver
    _shown = State(initialValue: favorites.selection)
  }

  var body: some View {
    GeometryReader { geometry in
      let page = favorites.pages.first { $0.id == shown }
      ZStack {
        ZStack {
          if favorites.showAllMedia {
            FavoriteLibrary(favorites: favorites)
          } else if let page {
            FavoriteGallery(page: page, player: player, favorites: favorites)
          } else {
            PrismBackground()
              .overlay(alignment: .bottom) {
                let bottomInset: CGFloat = favorites.pages.isEmpty ? 0 : 60
                let projection = PrismScene.view(
                  aspect: geometry.size.width / max(geometry.size.height, 1), orbit: .zero
                ).viewProjection
                let corner =
                  projection
                  * SIMD4(PrismScene.triangle[2].x, PrismScene.triangle[2].y, PrismScene.frontZ, 1)
                let prismBottom = geometry.size.height * (1 - corner.y / corner.w) / 2
                VStack(spacing: 16) {
                  Text("Drop media here or double-click to open.")
                    .font(.system(size: 15)).foregroundStyle(.secondary)
                  if let message = player.engineError {
                    Label(message, systemImage: "exclamationmark.circle")
                      .font(.system(size: 11)).foregroundStyle(.orange)
                  }
                }
                .shadow(color: .black, radius: 3)
                .padding(.horizontal, 40)
                .frame(height: max(0, geometry.size.height - prismBottom - bottomInset))
                .padding(.bottom, bottomInset)
                .allowsHitTesting(false)
              }
              .contentShape(Rectangle())
              .onTapGesture(count: 2) { player.openFiles() }
              .gesture(WindowDragGesture())
          }
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
        .clipped()
        .compositingGroup()
        .id(shown)
        .transition(
          reduceMotion
            ? .identity
            : .asymmetric(
              insertion: .offset(x: favorites.forward ? geometry.size.width : -geometry.size.width),
              removal: .offset(x: favorites.forward ? -geometry.size.width : geometry.size.width)
            )
        )
        .zIndex(1)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
      .overlay { if page == nil && !favorites.showAllMedia { PlayerContextMenu(player: player) } }
      .overlay(alignment: .bottom) {
        if !favorites.pages.isEmpty && !favorites.showAllMedia {
          StartPageFooter {
            HStack(spacing: 4) {
              FavoriteDots(
                favorites: favorites, shown: shown, tooltip: $tooltip, sorting: $sortingDots)
              Button {
                tooltip = nil
                favorites.showAllMedia = true
              } label: {
                Image(systemName: "play.square.stack.fill").font(.system(size: 15, weight: .medium))
                  .foregroundStyle(.white.opacity(libraryHovered ? 1 : 0.7))
                  .frame(width: 32, height: 36).contentShape(Rectangle())
              }
              .buttonStyle(.plain).help("Library · ⇧⌘L").accessibilityLabel("Library")
              .onHover { libraryHovered = $0 }
              .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: libraryHovered)
              Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 20).padding(
                .horizontal, 4)
              Button {
                let panel = NSOpenPanel()
                panel.title = "Choose Media Files or Folders"
                panel.prompt = "Choose"
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = true
                panel.allowedContentTypes = MediaItem.libraryTypes
                panel.begin { response in
                  if response == .OK { favorites.prepareDraft(panel.urls, player: player) }
                }
              } label: {
                Image(systemName: "plus").font(.system(size: 15, weight: .medium))
                  .foregroundStyle(.white.opacity(addHovered ? 1 : 0.7))
                  .frame(width: 32, height: 36).contentShape(Rectangle())
              }
              .buttonStyle(.plain).help("Add to Library…").accessibilityLabel("Add to Library")
              .onHover { addHovered = $0 }
              .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: addHovered)
              .disabled(!favorites.ready || favorites.saving)
            }
            .padding(.horizontal, 8)
            .glassEffect(.regular.tint(.black.opacity(0.2)), in: Capsule())
            .overlay { PageScroll(favorites: favorites) }
            if let updateDriver { UpdateBar(driver: updateDriver) }
          }
          .padding(.horizontal, 16)
          .padding(.bottom, 24)
        }
      }
      .overlayPreferenceValue(PosterAnchor.self) { anchor in
        if !favorites.showAllMedia, let anchor,
          let page = favorites.pages.first(where: { $0.id == tooltip }),
          let poster = page.info?.posterURL
        {
          GeometryReader { proxy in
            let dot = proxy[anchor]
            FavoriteArtwork(url: page.artworkURL(poster), background: true, maxPixelSize: 320)
              .frame(width: 96, height: 144).coverBorder(cornerRadius: 6)
              .padding(6).padding(.bottom, 8)
              .glassEffect(
                .regular.tint(.black.opacity(0.2)),
                in: ArrowOutline(top: false, depth: 8, radius: 10)
              )
              .shadow(color: .black.opacity(0.3), radius: 8)
              .frame(height: 0, alignment: .bottom)
              .position(x: dot.midX, y: dot.minY - 4)
              .animation(reduceMotion || sortingDots ? nil : .easeInOut(duration: 0.18), value: dot)
          }
          .allowsHitTesting(false)
          .transition(.identity)
        }
      }
    }
    .background(.black)
    .onChange(of: favorites.selection) {
      withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.4)) { shown = favorites.selection }
    }
  }
}

private struct StartPageFooter: Layout {
  private func sizes(width: CGFloat, subviews: Subviews) -> (navigation: CGSize, update: CGSize) {
    let navigation = subviews[0].sizeThatFits(.unspecified)
    let available = max(0, width - navigation.width - 8)
    let update = subviews.dropFirst().first?.sizeThatFits(.init(width: available, height: nil)) ?? .zero
    return (navigation, update)
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? subviews[0].sizeThatFits(.unspecified).width
    let row = sizes(width: width, subviews: subviews)
    return CGSize(width: width, height: max(row.navigation.height, row.update.height))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let row = sizes(width: bounds.width, subviews: subviews)
    let centerX = min(bounds.midX, bounds.maxX - row.update.width - 8 - row.navigation.width / 2)
    subviews[0].place(at: CGPoint(x: centerX, y: bounds.midY),
                      anchor: .center, proposal: ProposedViewSize(row.navigation))
    subviews.dropFirst().first?.place(at: CGPoint(x: bounds.maxX, y: bounds.midY),
                                     anchor: .trailing, proposal: ProposedViewSize(row.update))
  }
}

struct PosterAnchor: PreferenceKey {
  static var defaultValue: Anchor<CGRect>? { nil }
  static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
    value = nextValue() ?? value
  }
}

private struct PageScroll: NSViewRepresentable {
  let favorites: FavoritePages

  func makeNSView(context: Context) -> Control { Control() }
  func updateNSView(_ view: Control, context: Context) { view.favorites = favorites }

  final class Control: NSView {
    var favorites: FavoritePages?
    private var lastScrollTime = -Double.infinity
    private var distance: CGFloat = 0
    private var scrolled = false

    override func hitTest(_ point: NSPoint) -> NSView? {
      NSApp.currentEvent?.type == .scrollWheel ? super.hitTest(point) : nil
    }

    override func scrollWheel(with event: NSEvent) {
      guard let favorites, event.momentumPhase.isEmpty, NSEvent.pressedMouseButtons == 0 else {
        return
      }
      if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
        distance = 0
        scrolled = false
        return
      }
      let delta =
        abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        ? event.scrollingDeltaX : event.scrollingDeltaY
      if event.phase.contains(.began) || event.timestamp - lastScrollTime > 0.25
        || delta * distance < 0
      {
        distance = 0
        scrolled = false
      }
      lastScrollTime = event.timestamp
      if event.hasPreciseScrollingDeltas || !event.phase.isEmpty {
        guard !scrolled else { return }
        distance += delta
        guard abs(distance) >= 24 else { return }
        scrolled = true
      } else {
        distance = delta
        guard distance != 0 else { return }
      }
      favorites.movePage(by: distance < 0 ? 1 : -1)
    }
  }
}

private struct FavoriteLibrary: View {
  let favorites: FavoritePages
  @AppStorage("libraryFilter") private var filter = ""
  @AppStorage("librarySortByYear") private var sortByYear = false
  @State private var search = ""
  @State private var showOptions = false
  @FocusState private var gridFocused: Bool

  var body: some View {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    let pages = favorites.pages.filter { page in
      (filter.isEmpty || page.info?.mediaType.rawValue == filter)
        && (query.isEmpty || page.displayTitle.localizedStandardContains(query)
          || page.info?.title.localizedStandardContains(query) == true
          || page.media.contains { $0.lastPathComponent.localizedStandardContains(query) })
    }.sorted { lhs, rhs in
      if sortByYear {
        let leftYear = lhs.info?.releaseDate.flatMap { Int($0.prefix(4)) } ?? 0
        let rightYear = rhs.info?.releaseDate.flatMap { Int($0.prefix(4)) } ?? 0
        if leftYear != rightYear { return leftYear > rightYear }
      }
      return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }
    VStack(spacing: 20) {
      HStack(spacing: 16) {
        IconButton(symbol: "chevron.backward", label: "Back", help: "Back · Esc") {
          if showOptions { showOptions = false } else { favorites.showAllMedia = false }
        }
        .keyboardShortcut(.cancelAction)
        .frame(width: 36, height: 36)
        .glassEffect(.regular.interactive(), in: Circle())
        HStack(spacing: 10) {
          Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
          TextField("Search", text: $search).textFieldStyle(.plain)
          if !search.isEmpty {
            Button {
              search = ""
            } label: {
              Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).help("Clear Search").accessibilityLabel("Clear Search")
          }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .glassEffect(.regular, in: Capsule())
        .frame(maxWidth: 420)
        Text("^[\(pages.count) item](inflect: true)")
          .font(.system(size: 12)).foregroundStyle(.secondary)
        Spacer(minLength: 0)
        Button {
          showOptions.toggle()
        } label: {
          Image(systemName: "line.3.horizontal.decrease.circle")
            .font(.system(size: 18))
            .foregroundStyle(filter.isEmpty ? Color.primary : Color.accentColor)
            .frame(width: 36, height: 36).contentShape(Circle())
        }
        .buttonStyle(.plain).glassEffect(.regular.interactive(), in: Circle())
        .help("Filter and Sort").accessibilityLabel("Filter and Sort")
        .popover(isPresented: $showOptions, arrowEdge: .bottom) {
          VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
              Text("Type").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
              HStack(spacing: 2) {
                ForEach(
                  ["", TMDBTitle.MediaType.movie.rawValue, TMDBTitle.MediaType.tv.rawValue],
                  id: \.self
                ) { type in
                  Button {
                    filter = type
                  } label: {
                    Text(
                      type.isEmpty
                        ? "All" : type == TMDBTitle.MediaType.movie.rawValue ? "Movies" : "TV"
                    )
                    .padding(.horizontal, 10).frame(height: 24).contentShape(Capsule())
                  }
                  .buttonStyle(.plain)
                  .background(filter == type ? .white.opacity(0.2) : .clear, in: Capsule())
                  .accessibilityAddTraits(filter == type ? .isSelected : [])
                }
              }
              .padding(2).glassEffect(.regular, in: Capsule())
            }
            VStack(alignment: .leading, spacing: 8) {
              Text("Sort by").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
              HStack(spacing: 2) {
                ForEach([false, true], id: \.self) { byYear in
                  Button {
                    sortByYear = byYear
                  } label: {
                    Text(byYear ? "Year" : "Name")
                      .padding(.horizontal, 10).frame(height: 24).contentShape(Capsule())
                  }
                  .buttonStyle(.plain)
                  .background(sortByYear == byYear ? .white.opacity(0.2) : .clear, in: Capsule())
                  .accessibilityAddTraits(sortByYear == byYear ? .isSelected : [])
                }
              }
              .padding(2).glassEffect(.regular, in: Capsule())
            }
          }
          .padding(16).fixedSize().preferredColorScheme(.dark)
        }
      }
      .padding(.horizontal, 40)
      ScrollView {
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 20, alignment: .top)],
          spacing: 24
        ) {
          ForEach(pages) { page in
            let title = page.displayTitle
            Button {
              favorites.select(page.id)
            } label: {
              VStack(alignment: .leading, spacing: 10) {
                ZStack {
                  Rectangle().fill(.white.opacity(0.06))
                  if let poster = page.info?.posterURL {
                    FavoriteArtwork(url: page.artworkURL(poster), maxPixelSize: 720)
                  } else {
                    Image(systemName: "rectangle.stack").font(
                      .system(size: 36, weight: .ultraLight)
                    )
                    .foregroundStyle(.secondary)
                  }
                }
                .aspectRatio(2 / 3, contentMode: .fit)
                .coverBorder(cornerRadius: 12)
                VStack(alignment: .leading, spacing: 0) {
                  Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                  Group {
                    if let info = page.info {
                      Text(info.releaseDate.map { String($0.prefix(4)) } ?? "")
                    } else {
                      Text("^[\(page.media.count) file](inflect: true)")
                    }
                  }
                  .font(.system(size: 11)).foregroundStyle(.secondary)
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Open \(title)")
            .contextMenu {
              Button("\(page.editTitle)…") { favorites.draft = [page] }
              Button("Remove from Library…", role: .destructive) {
                favorites.pendingDeletion = page
              }
            }
          }
        }
        .padding(.horizontal, 40).padding(.bottom, 24)
      }
      .focusable().focused($gridFocused).focusEffectDisabled(gridFocused)
      .overlay {
        if pages.isEmpty {
          if favorites.pages.isEmpty {
            ContentUnavailableView {
              Label {
                Text("Library Is Empty").font(.body.weight(.regular)).foregroundStyle(.secondary)
              } icon: {
                Image(systemName: "rectangle.stack")
              }
            }
          } else if !query.isEmpty {
            ContentUnavailableView.search(text: query)
          } else {
            ContentUnavailableView("No items", systemImage: "info.circle")
          }
        }
      }
    }
    .padding(.top, 52).background(Color(white: 0.035))
    .defaultFocus($gridFocused, true)
  }
}

private struct FavoriteGallery: View {
  let page: FavoritePage
  let player: PlayerModel
  let favorites: FavoritePages
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var backgroundIndex = 0

  var body: some View {
    let backgrounds =
      page.background.map { [$0] }
      ?? ([page.info?.backgroundURL].compactMap { $0 }
      + (page.info?.backgroundURLs ?? []).filter { $0 != page.info?.backgroundURL }).map(
        page.artworkURL)
    GeometryReader { geometry in
      let width = min(
        min(640, max(280, geometry.size.width * 0.64)), max(72, geometry.size.height - 200) * 16 / 9
      )
      ZStack {
        Color(red: 0.035, green: 0.035, blue: 0.045)
        if !backgrounds.isEmpty {
          FavoriteArtwork(
            url: backgrounds[backgroundIndex % backgrounds.count], background: true, crossfade: true
          )
          Color.black.opacity(0.48)
          LinearGradient(
            colors: [.black.opacity(0.15), .black.opacity(0.8)], startPoint: .top, endPoint: .bottom
          )
        }
        ScrollView(.horizontal) {
          LazyHStack(alignment: .top, spacing: 32) {
            let latest = page.media.lazy.filter { player.progress[$0] != nil }.max {
              (player.progress[$0]?.date ?? .distantPast)
                < (player.progress[$1]?.date ?? .distantPast)
            }
            if let info = page.info {
              let height = width * 9 / 16
              let posterWidth = info.posterURL == nil ? 0 : height * 2 / 3 + height * 0.05 + 40
              FavoriteDetails(
                page: page, info: info, player: player, latest: latest, height: height,
                infoWidth: min(
                  640, max(280, geometry.size.width * 0.48),
                  geometry.size.width - 80 - posterWidth - (page.media.isEmpty ? 0 : 32 + 96))
              )
              .id(info.url)
            }
            ForEach(page.media, id: \.self) { url in
              let item = MediaItem(url: url, name: page.title(for: url))
              FavoriteMediaCard(
                item: item, artwork: page.artwork(for: url), player: player,
                lastPlayed: page.media.count > 1 && url == latest, width: width
              ) { restart in
                player.add(page.media, startingAt: url, page: page, restart: restart)
              }
            }
          }
          .scrollTargetLayout()
          .frame(height: width * 9 / 16 + 32)
          .frame(minHeight: max(0, geometry.size.height - 160))
        }
        .scrollPosition(
          id: Binding(
            get: { favorites.selection == page.id ? favorites.previewSelection : nil },
            set: {
              if favorites.selection == page.id { favorites.previewSelection = $0 }
            }), anchor: .leading
        )
        .animation(
          reduceMotion ? nil : .easeInOut(duration: 0.2), value: favorites.previewSelection
        )
        .contentMargins(.leading, 80, for: .scrollContent)
        .contentMargins(.trailing, 40, for: .scrollContent)
        .scrollClipDisabled()
        .scrollIndicators(.hidden)
        .padding(.top, 64).padding(.bottom, 96)
      }
    }
    .onChange(of: backgrounds) { backgroundIndex = 0 }
    .task(id: scenePhase == .active ? backgrounds : []) {
      guard scenePhase == .active, backgrounds.count > 1 else { return }
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(10)) } catch { return }
        backgroundIndex = (backgroundIndex + 1) % backgrounds.count
      }
    }
  }
}

private struct FavoriteDetails: View {
  let page: FavoritePage
  let info: TMDBTitle
  let player: PlayerModel
  let latest: URL?
  let height: CGFloat
  let infoWidth: CGFloat
  @State private var textHeight: CGFloat = 0

  var body: some View {
    HStack(alignment: .top, spacing: 40) {
      if let poster = info.posterURL {
        FavoriteArtwork(url: page.artworkURL(poster))
          .frame(width: height * 2 / 3, height: height)
          .coverBorder(cornerRadius: 16)
          .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
          .scaleEffect(1.15, anchor: .center)
          .padding(.trailing, height * 0.05)
      }
      VStack(alignment: .leading, spacing: 16) {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
              Text(page.title).font(.system(size: height < 270 ? 24 : 32, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
              let year = info.releaseDate.map { String($0.prefix(4)) }.flatMap {
                $0.isEmpty ? nil : $0
              }
              Text(
                [year, info.mediaType == .movie ? "Movie" : "TV Show"].compactMap { $0 }.joined(
                  separator: " · ") + page.seasonSuffix
              )
              .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Text(info.overview.isEmpty ? "No overview available." : info.overview)
              .font(.system(size: 14)).lineSpacing(4).foregroundStyle(.white.opacity(0.85))
              .fixedSize(horizontal: false, vertical: true)
            let credits = (info.credits ?? []).filter {
              $0.role == "Director" || $0.role == "Writer" || $0.role == "Cast"
            }
            if !credits.isEmpty {
              Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 8) {
                ForEach(credits, id: \.role) { credit in
                  let names = credit.names.joined(separator: ", ")
                  GridRow {
                    Text(credit.role).foregroundStyle(.secondary).fixedSize()
                    ViewThatFits(in: .horizontal) {
                      ForEach((0...min(3, credit.names.count)).reversed(), id: \.self) { count in
                        HStack(spacing: 6) {
                          if count > 0 {
                            Text(credit.names.prefix(count).joined(separator: ", "))
                          }
                          if count < credit.names.count {
                            Text("+\(credit.names.count - count)").foregroundStyle(.secondary)
                          }
                        }
                        .fixedSize()
                      }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(names).accessibilityElement(children: .ignore).accessibilityLabel(names)
                  }
                }
              }
              .font(.system(size: 12)).foregroundStyle(.white.opacity(0.85))
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .onGeometryChange(for: CGFloat.self) {
            $0.size.height
          } action: {
            textHeight = $0
          }
        }
        .frame(idealHeight: textHeight, maxHeight: textHeight == 0 ? nil : textHeight)
        HStack(spacing: 12) {
          if let url = latest ?? page.media.first {
            let saved = player.progress[url]
            let label = (saved?.time ?? 0) > 0 && saved?.finished == false ? "Resume" : "Play"
            Button {
              player.add(page.media, startingAt: url, page: page)
            } label: {
              HStack(spacing: 6) {
                Image(systemName: "play.fill")
                Text(label)
              }
              .font(.system(size: 12, weight: .medium))
              .padding(.horizontal, 12).padding(.vertical, 8)
              .contentShape(Capsule())
            }
            .buttonStyle(.plain).glassEffect(.clear.interactive(), in: Capsule())
            .accessibilityLabel("\(label) \(page.title)")
          }
          Link(destination: info.url) {
            HStack(spacing: 6) {
              if let logo = tmdbLogo {
                Image(nsImage: logo).resizable().scaledToFit().frame(width: 22, height: 16)
              } else {
                Text("TMDB").font(.system(size: 12, weight: .medium))
              }
              Text("More Info").font(.system(size: 12, weight: .medium))
              Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .contentShape(Capsule())
          }
          .buttonStyle(.plain).glassEffect(.clear.interactive(), in: Capsule())
          .help("Open on TMDB").accessibilityLabel("Open \(page.title) on TMDB")
        }
      }
      .frame(width: infoWidth, height: height, alignment: .topLeading)
    }
  }
}

private struct FavoriteMediaCard: View {
  let item: MediaItem
  let artwork: URL?
  let player: PlayerModel
  let lastPlayed: Bool
  let width: CGFloat
  let open: (Bool) -> Void
  @State private var preview: MediaPreview?
  @State private var hovered = false

  var body: some View {
    let progress = player.progress[item.url]
    Button {
      player.requestPlay(item, play: open)
    } label: {
      VStack(alignment: .leading, spacing: 14) {
        FavoriteArtwork(
          url: artwork ?? item.url, image: preview?.image,
          loading: artwork == nil && preview == nil && player.engineError == nil
        )
        .frame(width: width, height: width * 9 / 16)
        .coverBorder(cornerRadius: 24)
        .modifier(
          PlaybackBadges(
            item: item, lastPlayed: lastPlayed, duration: preview?.duration ?? progress?.duration,
            hovered: hovered, inset: 18))
        Text(item.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
          .padding(.horizontal, 4)
      }
      .frame(width: width, alignment: .leading).contentShape(Rectangle())
    }
    .buttonStyle(.plain).accessibilityLabel("Open \(item.title)")
    .onHover { hovered = $0 }
    .accessibilityValue(
      item.isImage
        ? ""
        : progress?.finished == true
          ? "Finished" : "\(Int((progress?.fraction ?? 0) * 100))% played"
    )
    .task(id: [player.engineVersion, artwork?.absoluteString, item.url.absoluteString]) {
      preview = nil
      guard player.engineVersion != nil, let engine = player.engine else { return }
      let loaded =
        artwork == nil
        ? await engine.preview(of: item.url)
        : MediaPreview(duration: await engine.details(of: item.url).duration)
      if !Task.isCancelled { preview = loaded }
    }
  }
}

private struct PlaybackBadges: ViewModifier {
  let item: MediaItem
  let lastPlayed: Bool
  let duration: Double?
  let hovered: Bool
  let inset: CGFloat

  func body(content: Content) -> some View {
    content
      .overlay(alignment: .topLeading) {
        if lastPlayed {
          Text("Last Played")
            .font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .glassEffect(.regular, in: Capsule())
            .padding(inset)
        }
      }
      .overlay(alignment: .bottomLeading) {
        if hovered {
          Image(systemName: item.isImage ? "photo" : "play.fill")
            .font(.system(size: 17, weight: .semibold))
            .frame(width: 44, height: 44)
            .glassEffect(.regular, in: Circle())
            .padding(inset)
        }
      }
      .overlay(alignment: .bottomTrailing) {
        if !item.isImage {
          Text(duration.map(timeLabel) ?? "—")
            .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .glassEffect(.regular, in: Capsule())
            .padding(inset)
        }
      }
  }
}

extension View {
  func coverBorder(cornerRadius: CGFloat) -> some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius)
    return clipShape(shape).overlay {
      shape.strokeBorder(.white.opacity(0.1), lineWidth: 1).allowsHitTesting(false)
    }
  }
}

struct FavoriteArtwork: View {
  let url: URL
  var background = false
  var crossfade = false
  var image: CGImage?
  var loading = false
  var symbol: String?
  var symbolSize: CGFloat = 48
  var maxPixelSize = 2560
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var backgroundImage: CGImage?
  @State private var loadingArtwork = false
  private static var loads: [String: Task<CGImage?, Never>] = [:]
  private static let cache: NSCache<NSString, CGImage> = {
    let cache = NSCache<NSString, CGImage>()
    cache.totalCostLimit = 64 * 1024 * 1024
    return cache
  }()

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        LinearGradient(
          colors: [Color(white: 0.16), Color(white: 0.07)], startPoint: .topLeading,
          endPoint: .bottomTrailing)
        if let image = backgroundImage ?? image {
          Image(decorative: image, scale: 1).resizable().scaledToFill()
            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
            .id(ObjectIdentifier(image)).transition(.opacity).zIndex(1)
        } else if loading || (loadingArtwork && !crossfade) {
          ProgressView().controlSize(.small).tint(.white)
        } else if !background {
          let item = MediaItem(url: url)
          Image(
            systemName: symbol ?? (item.isImage ? "photo" : item.isAudio ? "music.note" : "film")
          )
          .font(.system(size: symbolSize, weight: .ultraLight)).foregroundStyle(.white.opacity(0.3))
        }
      }
      .animation(
        crossfade && !reduceMotion ? .easeInOut(duration: 1) : nil,
        value: backgroundImage.map(ObjectIdentifier.init))
    }
    .accessibilityHidden(true)
    .task(id: url) {
      if !crossfade { backgroundImage = nil }
      loadingArtwork = false
      guard
        background || !url.isFileURL
          || url.deletingLastPathComponent().lastPathComponent == "Artwork"
      else { return }
      // Small views decode small images, so their thumbnails do not push large backdrops out of the cache.
      let key = "\(maxPixelSize) \(url.absoluteString)" as NSString
      if let cached = Self.cache.object(forKey: key) {
        backgroundImage = cached
        return
      }
      loadingArtwork = true
      defer { if !Task.isCancelled { loadingArtwork = false } }
      if Self.loads[key as String] == nil {
        let size = maxPixelSize
        Self.loads[key as String] = Task.detached(priority: .utility) {
          let source: CGImageSource?
          if url.isFileURL {
            source = CGImageSourceCreateWithURL(url as CFURL, nil)
          } else {
            guard
              let (data, response) = try? await URLSession.shared.data(
                for: URLRequest(url: url, timeoutInterval: 15)),
              (response as? HTTPURLResponse)?.statusCode == 200
            else { return nil }
            source = CGImageSourceCreateWithData(data as CFData, nil)
          }
          return thumbnail(source, maxPixelSize: size)
        }
      }
      let result = await Self.loads[key as String]?.value
      Self.loads[key as String] = nil
      guard let result else { return }
      Self.cache.setObject(result, forKey: key, cost: result.bytesPerRow * result.height)
      if !Task.isCancelled { backgroundImage = result }
    }
  }
}

struct FavoriteEditor: View {
  let favorites: FavoritePages
  @State var pages: [FavoritePage]
  let player: PlayerModel
  let compact: Bool
  @State private var loading = false
  @State private var addingFiles = false
  @State private var deleteOriginals = false
  @State private var originalsToDelete: Set<URL> = []
  @State private var pendingFiles: [URL]?
  @State private var pendingReplacements: [URL: URL]?
  @State private var bodyHeight: CGFloat = 0
  @State private var lookupStatus: [UUID: (message: String, retry: Bool)] = [:]
  @State private var lookupAttempt = 0
  @State private var resolvedInputs: [UUID: [String]] = [:]
  @State private var subtitled: Set<URL> = []
  @FocusState private var focused: UUID?

  private var canSave: Bool {
    favorites.ready && !favorites.saving && !pages.isEmpty
      && pages.allSatisfy {
        !$0.media.isEmpty && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      } && !loading && !addingFiles
  }

  var body: some View {
    let isEditing = pages.count == 1 && favorites.pages.contains { $0.id == pages[0].id }
    let inset: CGFloat = compact ? 12 : 28
    let sections = ForEach($pages) { $page in
      VStack(alignment: .leading, spacing: compact ? 8 : 16) {
        if page.info == nil {
          TextField("Name", text: $page.title)
            .textFieldStyle(.roundedBorder).focused($focused, equals: page.id)
          Text("TMDB information is optional.")
            .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        if let status = lookupStatus[page.id] {
          HStack(spacing: 12) {
            Text(status.message).font(.system(size: 12)).foregroundStyle(.secondary)
            if status.retry {
              Button("Retry") {
                resolvedInputs[page.id] = nil
                lookupAttempt += 1
              }
              .controlSize(.small)
            }
          }
        }
        if let info = page.info {
          HStack(alignment: .top, spacing: 12) {
            if let poster = info.posterURL {
              FavoriteArtwork(url: page.artworkURL(poster), background: true, maxPixelSize: 160)
                .frame(width: 52, height: 78).coverBorder(cornerRadius: 6)
            }
            VStack(alignment: .leading, spacing: 4) {
              Text(info.title).font(.system(size: 13, weight: .semibold))
              Text(info.overview).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
              Link(destination: info.url) {
                Text("TMDB \(Image(systemName: "arrow.up.right"))")
              }.font(.system(size: 10)).buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            Button {
              page.clearedInfoTitle = page.title
              page.info = nil
              page.episodeTitles = nil
              page.episodeImages = nil
              lookupStatus[page.id] = nil
              lookupAttempt += 1
              focused = page.id
            } label: {
              Image(systemName: "xmark").frame(width: 20, height: 20)
            }
            .buttonBorderShape(.circle).controlSize(.mini).help("Clear TMDB Information")
            .accessibilityLabel("Clear TMDB Information")
          }
        } else if !loading && page.media.contains(where: { MediaItem(url: $0).isVideo }) {
          HStack {
            Button {
              page.clearedInfoTitle = nil
              resolvedInputs[page.id] = nil
              lookupAttempt += 1
            } label: {
              Label("Search TMDB", systemImage: "magnifyingglass")
            }
            Spacer()
            if let logo = tmdbLogo {
              Link(destination: URL(string: "https://www.themoviedb.org/")!) {
                HStack(spacing: 6) {
                  Text("Powered by").font(.system(size: 10)).foregroundStyle(.secondary)
                  Image(nsImage: logo).resizable().scaledToFit().frame(width: 25, height: 18)
                    .accessibilityLabel("TMDB")
                }
              }
              .buttonStyle(.plain).help("Open TMDB")
            }
          }
        }
        HStack {
          Text("Files").font(.headline)
          Spacer()
          Button("Add Files…") {
            let panel = NSOpenPanel()
            panel.title = "Choose Media Files or Folders"
            panel.prompt = "Add"
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = true
            panel.allowedContentTypes = MediaItem.libraryTypes
            panel.begin { response in
              guard response == .OK else { return }
              addingFiles = true
              Task {
                defer { addingFiles = false }
                do {
                  let groups = try await FavoritePage.drafts(for: panel.urls)
                  guard !groups.isEmpty else {
                    player.error = "This selection contains no supported media files."
                    return
                  }
                  let copied = await favorites.copiedSources()
                  var seen = Set(
                    (favorites.pages.filter { $0.id != page.id }.flatMap(\.media)
                      + pages.flatMap(\.media)).map(\.standardizedFileURL)
                  ).union(copied)
                  let media = groups.flatMap(\.media).filter {
                    seen.insert($0.standardizedFileURL).inserted
                  }
                  guard !media.isEmpty else {
                    player.error =
                      "No files were added. All selected files are already in your library or this item."
                    return
                  }
                  if isEditing { pendingFiles = media } else { page.media += media }
                } catch {
                  player.error =
                    "These files or folders are unavailable. Choose them from their current location."
                }
              }
            }
          }
          .disabled(addingFiles)
        }
        let files = LazyVStack(spacing: 8) {
          let lastEpisodes = (page.episodeTitles ?? [:]).keys.reduce(into: [Int: Int]()) {
            episodes, key in
            let numbers = key.split(separator: ":").compactMap { Int($0) }
            guard numbers.count == 2 else { return }
            episodes[numbers[0]] = max(episodes[numbers[0]] ?? 0, numbers[1])
          }
          ForEach(page.media, id: \.self) { url in
            FavoriteEditorRow(
              url: url, info: page.info, title: page.title(for: url), lastEpisodes: lastEpisodes,
              hasSubtitles: subtitled.contains(url), player: player
            ) {
              page.media.removeAll { $0 == url }
              originalsToDelete.remove(url)
            }
          }
          if page.media.isEmpty {
            Text("Add files to this library item.").foregroundStyle(.secondary).frame(
              maxWidth: .infinity, alignment: .leading)
          }
        }
        .font(.system(size: 12)).padding(.horizontal, 12)
        let height = CGFloat(min(max(page.media.count, 1), 5)) * 30 - 8
        ScrollView { files }
          .scrollBounceBehavior(.basedOnSize)
          .frame(idealHeight: height, maxHeight: height)
          .padding(.vertical, 12)
          .layoutPriority(-1)
          .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        if !isEditing, page.id == pages.last?.id {
          Toggle("Delete original files", isOn: $deleteOriginals).toggleStyle(.checkbox)
            .font(.system(size: 12))
            .help("Keep the files in the library and delete them from their original locations.")
        }
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text("Background Image").font(.system(size: 12, weight: .medium))
            Text(
              page.background?.lastPathComponent
                ?? ((page.info?.backgroundURLs?.isEmpty ?? true) && page.info?.backgroundURL == nil
                  ? "Optional" : "TMDB backdrops")
            )
            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
          }
          Spacer()
          if page.background != nil {
            Button {
              page.background = nil
            } label: {
              Image(systemName: "xmark")
            }
            .buttonBorderShape(.circle).controlSize(.mini).help("Clear Custom Background")
            .accessibilityLabel("Clear Custom Background")
          }
          Button("Choose…") {
            let panel = NSOpenPanel()
            panel.title = "Choose Background Image"
            panel.prompt = "Choose"
            panel.allowedContentTypes = [.image]
            panel.begin { response in if response == .OK { page.background = panel.url } }
          }
        }
        if page.id != pages.last?.id { Divider().padding(.vertical, 8) }
      }
    }
    let content = VStack(alignment: .leading, spacing: compact ? 8 : 20) {
      Text(isEditing ? pages[0].editTitle : "Add to Library").font(.title2.weight(.semibold))
        .frame(maxWidth: .infinity, alignment: .leading)
      if favorites.saving {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Adding files to the library…")
        }
        .font(.system(size: 12)).foregroundStyle(.secondary)
      }
      if loading {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("TMDB lookup in progress…")
        }
        .font(.system(size: 12)).foregroundStyle(.secondary)
      }
      if isEditing {
        sections.padding(4).layoutPriority(-1)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            sections
          }
          .padding(4)
          .onGeometryChange(for: CGFloat.self) {
            $0.size.height
          } action: {
            bodyHeight = $0
          }
        }
        .scrollBounceBehavior(.basedOnSize)
        .contentMargins(.trailing, inset - 8, for: .scrollContent)
        .padding(.trailing, 8 - inset)
        .frame(idealHeight: bodyHeight, maxHeight: bodyHeight == 0 ? nil : bodyHeight)
        .layoutPriority(-1)
      }
      HStack {
        if isEditing {
          Button("Remove", role: .destructive) { favorites.pendingDeletion = pages[0] }
            .help("Remove from Library…")
            .foregroundStyle(.red)
        }
        Spacer()
        Button("Cancel") { favorites.draft = nil }.keyboardShortcut(.cancelAction)
        Button(isEditing ? "Save" : "Add to Library") { save() }
        .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
        .disabled(!canSave)
      }
    }
    .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.large)
    .padding(inset).frame(width: 460)
    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 20))
    .glassEffect(.regular.tint(.black.opacity(0.25)), in: RoundedRectangle(cornerRadius: 20))
    content
      .disabled(favorites.saving)
      .alert(
        "Delete original files?",
        isPresented: Binding(get: { pendingFiles != nil }, set: { if !$0 { pendingFiles = nil } }),
        presenting: pendingFiles
      ) { media in
        Button("Keep Originals") { pages[0].media += media }.keyboardShortcut(.defaultAction)
        Button("Delete Originals", role: .destructive) {
          originalsToDelete.formUnion(media)
          pages[0].media += media
        }
        Button("Cancel", role: .cancel) {}
      } message: { _ in
        Text(
          "The library will keep a copy. Delete the selected files from their original locations when you save?"
        )
      }
      .alert(
        pendingReplacements?.count == 1 ? "Replace Library File?" : "Replace Library Files?",
        isPresented: Binding(
          get: { pendingReplacements != nil }, set: { if !$0 { pendingReplacements = nil } }),
        presenting: pendingReplacements
      ) { replacements in
        Button("Replace", role: .destructive) { save(replacing: replacements) }
        Button(replacements.count == 1 ? "Keep Both" : "Keep All") { save(replacing: [:]) }
        Button("Cancel", role: .cancel) {}
      } message: { replacements in
        if replacements.count == 1, let (old, new) = replacements.first {
          Text("Replace “\(old.lastPathComponent)” with “\(new.lastPathComponent)” in your library?")
        } else {
          Text("Replace \(replacements.count) matching files in your library?")
        }
      }
      .task {
        await Task.yield()
        focused = pages.first(where: { $0.info == nil })?.id
      }
      .task(id: pages.flatMap(\.media)) {
        let media = pages.flatMap(\.media).filter { !MediaItem(url: $0).isImage }
        let search = Task.detached(priority: .utility) {
          MediaItem.subtitleFiles(for: media) { Task.isCancelled }
        }
        let found = await withTaskCancellationHandler {
          await search.value
        } onCancel: {
          search.cancel()
        }
        if !Task.isCancelled { subtitled = Set(found.filter { !$0.value.isEmpty }.keys) }
      }
      .onExitCommand { if !favorites.saving { favorites.draft = nil } }
      .accessibilityAddTraits(.isModal)
      .task(id: [String(lookupAttempt)] + pages.flatMap { [$0.id.uuidString] + $0.lookupKey }) {
        loading = true
        defer { if !Task.isCancelled { loading = false } }
        var waited = false
        for (index, var updated) in pages.enumerated() {
          let id = updated.id
          let input = updated.lookupKey
          guard input != resolvedInputs[id], updated.clearedInfoTitle == nil,
            updated.info == nil || !updated.missingSeasons.isEmpty,
            let first = updated.media.first(where: { MediaItem(url: $0).isVideo })
          else { continue }
          lookupStatus[id] = nil
          do {
            if !waited {
              try await Task.sleep(for: .milliseconds(400))
              waited = true
            }
            if updated.info == nil {
              let filename = MediaFilename(first.deletingPathExtension().lastPathComponent)
              let name = MediaFilename(updated.title)
              let query = name.title.isEmpty ? filename.title : name.title
              guard !query.isEmpty else { continue }
              let year = name.year ?? filename.year
              let sameTitle = { (info: TMDBTitle) in
                info.title.compare(query, options: [.caseInsensitive, .diacriticInsensitive])
                  == .orderedSame
              }
              let sameYear = { (info: TMDBTitle) in
                year.map { info.releaseDate?.hasPrefix(String($0)) == true } ?? true
              }
              let cached = (favorites.pages + pages).compactMap(\.info).first { info in
                sameTitle(info) && info.mediaType == (filename.season == nil ? .movie : .tv)
                  && sameYear(info)
              }
              let matches: [TMDBTitle]
              if let cached {
                matches = [cached]
              } else {
                matches =
                  try await TMDB.load(
                    .init(query: query, type: filename.season == nil ? "multi" : "tv")
                  ).results ?? []
              }
              try Task.checkCancellation()
              guard
                let match = matches.first(where: { sameTitle($0) && sameYear($0) })
                  ?? matches.first(where: sameTitle) ?? matches.first
              else {
                resolvedInputs[id] = input
                lookupStatus[id] = ("TMDB found no match. Check the name and search again.", false)
                continue
              }
              updated.info = match
              updated.title = match.title
              let existing = favorites.pages.first {
                $0.info?.id == match.id && $0.info?.mediaType == match.mediaType
              }
              updated.episodeTitles = existing?.episodeTitles
              updated.episodeImages = existing?.episodeImages
            }
            let complete = try await updated.loadEpisodes()
            try Task.checkCancellation()
            guard pages.indices.contains(index), pages[index].id == id,
              input == pages[index].lookupKey,
              pages[index].clearedInfoTitle == nil
            else { return }
            if !complete {
              lookupStatus[id] = (
                "Some episode information is unavailable. You can save without it.", true
              )
            }
            pages[index].info = updated.info
            pages[index].clearedInfoTitle = nil
            pages[index].episodeTitles = updated.episodeTitles
            pages[index].episodeImages = updated.episodeImages
            resolvedInputs[id] = updated.lookupKey
            pages[index].title = updated.title
          } catch {
            if Task.isCancelled { return }
            resolvedInputs[id] = input
            lookupStatus[id] = ("TMDB information is unavailable. Try again.", true)
          }
        }
      }
  }

  private func save(replacing confirmed: [URL: URL]? = nil) {
    guard canSave, favorites.draft?.first?.id == pages.first?.id else { return }
    let library = favorites.pages
    var saved = library
    var seen = Set(library.flatMap(\.media).map(\.standardizedFileURL))
    var added: [UUID] = []
    var replacements: [URL: URL] = [:]
    for var page in pages {
      page.title = page.info?.title ?? page.title.trimmingCharacters(in: .whitespacesAndNewlines)
      page.clearedInfoTitle = page.info == nil ? page.title : nil
      if let index = saved.firstIndex(where: { $0.id == page.id }) {
        saved[index] = page
      } else {
        page.media.removeAll { !seen.insert($0.standardizedFileURL).inserted }
        guard !page.media.isEmpty else { continue }
        if let info = page.info,
          let index = saved.firstIndex(where: {
            $0.info?.id == info.id && $0.info?.mediaType == info.mediaType
          })
        {
          var existing = saved[index]
          if confirmed?.isEmpty != true,
            let original = library.first(where: { $0.id == existing.id })
          {
            let matches = original.matchingMedia(for: page.media)
            for (old, new) in matches where replacements[old] == nil { replacements[old] = new }
            if confirmed != nil {
              let oldFiles = Set(matches.map(\.old))
              existing.media.removeAll { oldFiles.contains($0) }
            }
          }
          existing.media += page.media
          existing.media.sort {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
          }
          existing.episodeTitles = (existing.episodeTitles ?? [:]).merging(
            page.episodeTitles ?? [:]
          ) { _, new in new }
          existing.episodeImages = (existing.episodeImages ?? [:]).merging(
            page.episodeImages ?? [:]
          ) { _, new in new }
          if let background = page.background { existing.background = background }
          saved[index] = existing
          page.id = existing.id
        } else {
          saved.append(page)
        }
      }
      if !added.contains(page.id) { added.append(page.id) }
    }
    if let confirmed {
      guard confirmed == replacements else {
        player.error = "The matching library files changed. Review the import and try again."
        return
      }
    } else if !replacements.isEmpty {
      pendingReplacements = replacements
      return
    }
    guard let first = added.first else {
      player.error = "No files were added. All selected files are already in your library."
      return
    }
    let originals = deleteOriginals ? Set(pages.flatMap(\.media)) : originalsToDelete
    Task {
      guard await favorites.save(saved, importing: Set(added), moving: originals) else { return }
      var moved: [URL: URL] = [:]
      for page in saved {
        guard let updated = favorites.pages.first(where: { $0.id == page.id }) else { continue }
        for (source, destination) in zip(page.media, updated.media)
        where source != destination { moved[source] = destination }
      }
      if let current = player.current {
        if replacements[current.url] != nil
          || (moved[current.url] != nil && originals.contains(current.url))
        {
          player.stop()
        } else if moved[current.url] != nil {
          player.saveProgress()
        }
      }
      if !moved.isEmpty {
        player.saveProgress(relocating: moved, copying: Set(moved.keys).subtracting(originals))
      }
      let latest = replacements.reduce(into: [URL: URL]()) { latest, pair in
        let (old, source) = pair
        guard let progress = player.progress[old] else { return }
        let destination = moved[source] ?? source
        // The new file can have newer progress than every replaced file.
        let previous =
          latest[destination].flatMap { player.progress[$0] } ?? player.progress[destination]
        if previous == nil || (progress.date ?? .distantPast) > (previous?.date ?? .distantPast) {
          latest[destination] = old
        }
      }
      if !latest.isEmpty {
        player.saveProgress(
          relocating: Dictionary(uniqueKeysWithValues: latest.map { destination, old in
            (old, destination)
          }))
      }
      favorites.draft = nil
      favorites.select(first)
      if added.count > 1 { favorites.showAllMedia = true }
    }
  }
}

private struct FavoriteEditorRow: View {
  let url: URL
  let info: TMDBTitle?
  let title: String
  let lastEpisodes: [Int: Int]
  let hasSubtitles: Bool
  let player: PlayerModel
  let remove: () -> Void
  @State private var details: MediaDetails?

  var body: some View {
    let item = MediaItem(url: url)
    let isVideo = item.isVideo
    let filename = MediaFilename(item.title)
    let numbers =
      info?.mediaType == .tv && isVideo
      ? filename.season.flatMap { season in filename.episode.map { (season: season, episode: $0) } }
      : nil
    let titleMismatch: Bool = {
      guard let info, isVideo else { return false }
      let titles = [filename.title, info.title].map {
        Array(
          $0.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
          )
          .filter { $0.isLetter || $0.isNumber })
      }
      let source = titles[0]
      let target = titles[1]
      guard !source.isEmpty, !target.isEmpty, source != target else { return false }
      let tolerance = min(source.count, target.count) / 5
      guard abs(source.count - target.count) <= tolerance,
        source.filter(\.isNumber) == target.filter(\.isNumber)
      else { return true }
      var distances = Array(0...target.count)
      for (i, character) in source.enumerated() {
        var diagonal = distances[0]
        distances[0] = i + 1
        for (j, other) in target.enumerated() {
          let previous = distances[j + 1]
          distances[j + 1] = min(
            distances[j] + 1, previous + 1, diagonal + (character == other ? 0 : 1))
          diagonal = previous
        }
        if distances.min()! > tolerance { return true }
      }
      return distances[target.count] > tolerance
    }()
    let warning: String? = {
      if let numbers, let lastEpisode = lastEpisodes[numbers.season], numbers.episode > lastEpisode
      {
        return
          "Episode \(numbers.episode) is beyond the last episode listed on TMDB for season \(numbers.season) (episode \(lastEpisode))."
      }
      return titleMismatch
        ? "Check whether “\(url.lastPathComponent)” matches “\(info?.title ?? "")”." : nil
    }()
    HStack {
      if let numbers {
        Text(String(format: "S%02dE%02d", numbers.season, numbers.episode))
          .monospacedDigit().foregroundStyle(.secondary).fixedSize()
      }
      Text(titleMismatch ? item.title : title).lineLimit(1).truncationMode(.middle).help(
        url.lastPathComponent)
      if hasSubtitles {
        Text("Sub").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
          .padding(.horizontal, 6).padding(.vertical, 2)
          .glassEffect(.regular, in: Capsule()).fixedSize()
          .help("Linked external subtitles").accessibilityLabel("Linked external subtitles")
      }
      if let warning {
        Image(systemName: "exclamationmark.triangle").foregroundStyle(.yellow)
          .help(warning).accessibilityLabel(warning)
      }
      Spacer()
      if info != nil, isVideo {
        if let duration = details?.duration ?? player.progress[url]?.duration {
          Text(timeLabel(duration)).monospacedDigit().foregroundStyle(.secondary).fixedSize()
        }
      }
      Button(action: remove) { Image(systemName: "xmark").frame(width: 20, height: 20) }
        .buttonBorderShape(.circle).controlSize(.mini).help("Remove File from This Item")
        .accessibilityLabel("Remove \(url.lastPathComponent) from This Item")
    }
    .frame(height: 22)
    .task(id: [player.engineVersion, info?.mediaType.rawValue, url.absoluteString]) {
      guard info != nil, isVideo, details == nil, player.engineVersion != nil,
        let engine = player.engine
      else { return }
      let loaded = await engine.details(of: url)
      if !Task.isCancelled { details = loaded }
    }
  }
}
