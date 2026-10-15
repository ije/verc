import AppKit
import ImageIO
import Observation
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

// Saved in UserDefaults. Add new fields as optionals, or saved favorites stop decoding.
struct FavoritePage: Identifiable, Codable {
    var id = UUID()
    var title = ""
    var media: [URL] = []
    var background: URL?
}

private struct StoredPage: Decodable {
    let page: FavoritePage?
    init(from decoder: any Decoder) { page = try? FavoritePage(from: decoder) }
}

@MainActor @Observable final class FavoritePages {
    var pages: [FavoritePage] {
        didSet {
            if let data = try? JSONEncoder().encode(pages) { UserDefaults.standard.set(data, forKey: "favoritePages") }
        }
    }
    private(set) var selection: UUID?
    private(set) var forward = true
    var draft: FavoritePage?

    init() {
        // Drop bad entries one by one. A failed decode of the whole list would be saved back as an empty list.
        pages = UserDefaults.standard.data(forKey: "favoritePages")
            .flatMap { try? JSONDecoder().decode([StoredPage].self, from: $0) }?
            .compactMap(\.page).filter { !$0.media.isEmpty } ?? []
    }

    func select(_ id: UUID?) {
        let ids = [nil] + pages.map { Optional($0.id) }
        forward = (ids.firstIndex(of: id) ?? 0) > (ids.firstIndex(of: selection) ?? 0)
        selection = id
    }
}

struct StartPage: View {
    let player: PlayerModel
    let favorites: FavoritePages
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Trails favorites.selection by one update. A removed page keeps the transition from its last render,
    // so it must render the new direction before it leaves.
    @State private var shown: UUID?

    init(player: PlayerModel, favorites: FavoritePages) {
        self.player = player
        self.favorites = favorites
        _shown = State(initialValue: favorites.selection)
    }

    var body: some View {
        GeometryReader { geometry in
            let page = favorites.pages.first { $0.id == shown }
            ZStack {
                PrismBackground(hidden: page != nil)
                    .overlay(alignment: .bottom) {
                        VStack(spacing: 16) {
                            Text("Drop media here or double-click to open.")
                                .font(.system(size: 15)).foregroundStyle(.secondary)
                            if let message = player.engineError {
                                Label(message, systemImage: "exclamationmark.circle")
                                    .font(.system(size: 11)).foregroundStyle(.orange)
                            }
                        }
                        .shadow(color: .black, radius: 3)
                        .padding(.horizontal, 40).padding(.bottom, 104)
                        .allowsHitTesting(false)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { player.openFiles() }
                    .gesture(WindowDragGesture())
                    .offset(x: page == nil ? 0 : -geometry.size.width)
                    .accessibilityHidden(page != nil)
                if let page {
                    FavoriteGallery(page: page, player: player) { favorites.draft = page }
                        .id(page.id)
                        .transition(reduceMotion ? .opacity : .asymmetric(
                            insertion: .move(edge: favorites.forward ? .trailing : .leading),
                            removal: .move(edge: favorites.forward ? .leading : .trailing)
                        ))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
            .overlay { PlayerContextMenu(player: player) }
            .overlay(alignment: .bottom) {
                HStack(spacing: 4) {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal) {
                            HStack(spacing: 0) {
                                ForEach([nil] + favorites.pages.map(Optional.some), id: \.?.id) { page in
                                    Button { favorites.select(page?.id) } label: {
                                        Circle().fill(.white.opacity(shown == page?.id ? 1 : 0.36))
                                            .frame(width: 8, height: 8).frame(width: 28, height: 36)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(page?.title ?? "Prism")
                                    .accessibilityAddTraits(shown == page?.id ? [.isSelected] : [])
                                    .help(page?.title ?? "Prism")
                                    .contextMenu {
                                        if let page {
                                            Button("Edit favorite…") { favorites.draft = page }
                                            Button("Remove favorite", role: .destructive) {
                                                if favorites.selection == page.id { favorites.select(nil) }
                                                favorites.pages.removeAll { $0.id == page.id }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                        .frame(width: min(CGFloat(favorites.pages.count + 1) * 28, max(28, geometry.size.width - 320)), height: 36)
                        .onChange(of: favorites.selection) {
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.4)) { shown = favorites.selection }
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { proxy.scrollTo(favorites.selection, anchor: .center) }
                        }
                    }
                    Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 16).padding(.horizontal, 4)
                    Button { favorites.draft = FavoritePage() } label: {
                        Image(systemName: "plus").font(.system(size: 15, weight: .medium))
                            .frame(width: 32, height: 36).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help("Add Favorite Media").accessibilityLabel("Add Favorite Media")
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .glassEffect(.regular.tint(.black.opacity(0.2)), in: Capsule())
                .padding(.bottom, 24)
            }
        }
        .background(.black)
    }
}

private struct FavoriteGallery: View {
    let page: FavoritePage
    let player: PlayerModel
    let edit: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position: URL?

    var body: some View {
        GeometryReader { geometry in
            let width = min(640, max(280, geometry.size.width * 0.64))
            let height = max(72, min(420, geometry.size.height - 270))
            ZStack {
                Color(red: 0.035, green: 0.035, blue: 0.045)
                if let background = page.background {
                    FavoriteArtwork(url: background, background: true)
                    Color.black.opacity(0.48)
                    LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                }
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(page.title).font(.system(size: 26, weight: .semibold)).lineLimit(1)
                            Text("^[\(page.media.count) item](inflect: true)").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(action: edit) { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
                            .buttonStyle(.glass).buttonBorderShape(.circle).help("Edit favorite").accessibilityLabel("Edit favorite")
                    }
                    .padding(.horizontal, 40)
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 24) {
                            ForEach(page.media, id: \.self) { url in
                                let item = MediaItem(url: url)
                                Button { player.add([url]) } label: {
                                    VStack(alignment: .leading, spacing: 14) {
                                        FavoriteArtwork(url: url)
                                            .frame(width: width, height: height)
                                            .clipShape(RoundedRectangle(cornerRadius: 24))
                                            .overlay(alignment: .bottomLeading) {
                                                Image(systemName: item.isImage ? "photo" : "play.fill")
                                                    .font(.system(size: 17, weight: .semibold))
                                                    .frame(width: 44, height: 44)
                                                    .glassEffect(.regular, in: Circle()).padding(18)
                                            }
                                        Text(item.title).font(.system(size: 17, weight: .semibold)).lineLimit(1).padding(.horizontal, 4)
                                        Text(item.detail).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 4)
                                    }
                                    .frame(width: width, alignment: .leading).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain).help(url.path).accessibilityLabel("Open \(item.title)")
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .contentMargins(.horizontal, 40, for: .scrollContent)
                    .scrollIndicators(.hidden).scrollTargetBehavior(.viewAligned)
                    .scrollPosition(id: $position, anchor: .leading)
                }
                .padding(.top, 48).padding(.bottom, 88)
            }
            .overlay(alignment: .bottomTrailing) {
                let index = position.flatMap { page.media.firstIndex(of: $0) } ?? 0
                HStack(spacing: 8) {
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { position = page.media[max(0, index - 1)] }
                    } label: { Image(systemName: "chevron.left").frame(width: 28, height: 28) }
                    .disabled(index == 0).accessibilityLabel("Previous media")
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { position = page.media[min(page.media.count - 1, index + 1)] }
                    } label: { Image(systemName: "chevron.right").frame(width: 28, height: 28) }
                    .disabled(index >= page.media.count - 1).accessibilityLabel("Next media")
                }
                .buttonStyle(.glass).buttonBorderShape(.circle)
                .padding(.trailing, 40).padding(.bottom, 29)
            }
        }
    }
}

private struct FavoriteArtwork: View {
    let url: URL
    var background = false
    @Environment(\.displayScale) private var displayScale
    @State private var image: NSImage?
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: [Color(white: 0.16), Color(white: 0.07)], startPoint: .topLeading, endPoint: .bottomTrailing)
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                } else if !background {
                    Image(systemName: MediaItem(url: url).isAudio ? "music.note" : "film")
                        .font(.system(size: 48, weight: .ultraLight)).foregroundStyle(.white.opacity(0.3))
                }
            }
        }
        .accessibilityHidden(true)
        .task(id: url) {
            image = nil
            let key = (url.absoluteString + (background ? "#background" : "#thumbnail")) as NSString
            if let cached = Self.cache.object(forKey: key) { image = cached; return }
            let result: CGImage?
            if background {
                result = await Task.detached(priority: .utility) {
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil as CGImage? }
                    return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 2560
                    ] as CFDictionary)
                }.value
            } else {
                let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 960, height: 640), scale: displayScale, representationTypes: .thumbnail)
                result = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
            }
            guard let result else { return }
            let loaded = NSImage(cgImage: result, size: .zero)
            Self.cache.setObject(loaded, forKey: key, cost: result.bytesPerRow * result.height)
            if !Task.isCancelled { image = loaded }
        }
    }
}

struct FavoriteEditor: View {
    let favorites: FavoritePages
    @State var page: FavoritePage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Favorite Media").font(.system(size: 25, weight: .semibold))
            TextField("Name", text: $page.title).textFieldStyle(.roundedBorder)
            HStack {
                Text("Media").font(.headline)
                Spacer()
                Button("Add files…") {
                    let panel = NSOpenPanel()
                    panel.title = "Choose favorite media"
                    panel.allowsMultipleSelection = true
                    panel.allowedContentTypes = [.audio, .movie, .image] + (MediaItem.audioExtensions.union(MediaItem.videoExtensions)).compactMap { UTType(filenameExtension: $0) }
                    panel.begin { response in
                        guard response == .OK else { return }
                        for url in panel.urls where !page.media.contains(url) { page.media.append(url) }
                    }
                }
                .buttonStyle(.glass)
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(page.media, id: \.self) { url in
                        HStack {
                            Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button { page.media.removeAll { $0 == url } } label: { Image(systemName: "xmark").frame(width: 20, height: 20) }
                                .buttonStyle(.plain).accessibilityLabel("Remove \(url.lastPathComponent)")
                        }
                    }
                    if page.media.isEmpty { Text("Choose files for this gallery.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                }
                .font(.system(size: 12)).padding(12)
            }
            .frame(height: 116).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Background picture").font(.system(size: 12, weight: .medium))
                    Text(page.background?.lastPathComponent ?? "Optional").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if page.background != nil {
                    Button { page.background = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("Remove background picture")
                }
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.title = "Choose a background picture"
                    panel.allowedContentTypes = [.image]
                    panel.begin { response in if response == .OK { page.background = panel.url } }
                }
                .buttonStyle(.glass)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
                Button("Save") {
                    page.title = page.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    if page.title.isEmpty { page.title = "Local Media" }
                    if let index = favorites.pages.firstIndex(where: { $0.id == page.id }) { favorites.pages[index] = page }
                    else { favorites.pages.append(page) }
                    dismiss()
                    favorites.select(page.id)
                }
                .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                .disabled(page.media.isEmpty)
            }
        }
        .padding(28).frame(width: 460)
    }
}
