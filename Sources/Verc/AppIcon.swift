import AppKit
import SwiftUI

enum AppIcon: String, CaseIterable, Identifiable {
  case original, prism, glass

  var id: Self { self }
  var title: String { rawValue.capitalized }
  private var resource: String {
    switch self {
    case .original: "Verc"
    case .glass: "VercGlass"
    case .prism: "VercPrism"
    }
  }

  @MainActor private static let images = Dictionary(
    uniqueKeysWithValues: allCases.compactMap { icon -> (AppIcon, NSImage)? in
      guard let url = Bundle.main.url(forResource: icon.resource, withExtension: "png"),
        let image = NSImage(contentsOf: url)
      else { return nil }
      return (icon, image)
    })

  @MainActor var image: NSImage? { Self.images[self] }

  @MainActor func apply() {
    guard let image else { return }
    NSApp.applicationIconImage = image
    // macOS adds an opaque backing to transparent bundle icons.
    let view = NSImageView(frame: NSRect(origin: .zero, size: NSApp.dockTile.size))
    view.image = image
    view.imageScaling = .scaleProportionallyUpOrDown
    view.autoresizingMask = [.width, .height]
    NSApp.dockTile.contentView = view
    NSApp.dockTile.display()
  }
}

struct IconPicker: View {
  @Binding var isPresented: Bool
  @AppStorage("appIcon") private var selection: AppIcon = .glass
  @FocusState private var focused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("App Icon").font(.system(size: 12, weight: .semibold))
      HStack(spacing: 8) {
        ForEach(AppIcon.allCases) { icon in
          Button {
            selection = icon
            icon.apply()
          } label: {
            VStack(spacing: 4) {
              if let image = icon.image {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 72, height: 72)
              }
              Text(icon.title).font(.system(size: 11, weight: .medium))
            }
            .padding(8).contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .background {
            RoundedRectangle(cornerRadius: 12)
              .fill(.white.opacity(selection == icon ? 0.12 : 0))
              .allowsHitTesting(false)
          }
          .accessibilityLabel(icon.title)
          .accessibilityAddTraits(selection == icon ? .isSelected : [])
        }
      }
    }
    .padding(14).fixedSize()
    .glassEffect(.clear.tint(.black.opacity(0.25)), in: RoundedRectangle(cornerRadius: 20))
    .preferredColorScheme(.dark)
    .focusable().focused($focused).focusEffectDisabled()
    .onAppear { focused = true }
    .onExitCommand { isPresented = false }
    .accessibilityAddTraits(.isModal)
  }
}
