import SwiftUI

struct FavoriteDots: View {
  let favorites: FavoritePages
  let shown: UUID?
  @Binding var tooltip: UUID?
  @Binding var sorting: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase
  @GestureState private var dragging = false
  @State private var hovered: UUID?
  @State private var drag: (id: UUID, index: Int, x: CGFloat)?
  @State private var raised: UUID?
  @State private var inside = false
  @State private var cancelled = false

  var body: some View {
    let count = min(favorites.pages.count, 5)
    let target = drag.map { min(max(Int(($0.x / 28).rounded()), 1), count) }
    let spring: Animation? = reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82)
    ZStack(alignment: .leading) {
      ForEach(
        Array(([nil] + favorites.pages.prefix(count).map(Optional.some)).enumerated()),
        id: \.element?.id
      ) { index, page in
        let active = drag?.id == page?.id && page != nil
        let slot =
          if let drag, let target, index > 0, index != drag.index {
            index
              + (drag.index < index && index <= target
                ? -1 : target <= index && index < drag.index ? 1 : 0)
          } else { index }
        let x = active ? (drag?.x ?? 0) : CGFloat(slot) * 28
        let title = page?.displayTitle ?? "Home"
        Button {
          favorites.select(page?.id)
        } label: {
          Circle().fill(.white.opacity(shown == page?.id || active ? 1 : 0.36))
            .frame(width: 8, height: 8)
            .scaleEffect(active && !reduceMotion ? 1.5 : 1)
            .offset(y: active && !reduceMotion ? -2 : 0)
            .animation(spring, value: active)
            .anchorPreference(key: PosterAnchor.self, value: .bounds) {
              page?.id == tooltip ? $0 : nil
            }
            .frame(width: 28, height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(shown == page?.id ? [.isSelected] : [])
        .accessibilityActions {
          if index > 1 {
            Button("Move Left") {
              favorites.pages.move(fromOffsets: IndexSet(integer: index - 1), toOffset: index - 2)
            }
          }
          if index > 0, index < count {
            Button("Move Right") {
              favorites.pages.move(fromOffsets: IndexSet(integer: index - 1), toOffset: index + 1)
            }
          }
        }
        .help(page?.info?.posterURL == nil ? title : "")
        .onHover { active in
          guard active, drag == nil, !cancelled else { return }
          hovered = page?.info?.posterURL == nil ? nil : page?.id
          if hovered == nil || tooltip != nil { tooltip = hovered }
        }
        .contextMenu {
          if let page {
            Button("\(page.editTitle)…") { favorites.draft = [page] }
            Button("Remove from Library…", role: .destructive) { favorites.pendingDeletion = page }
          }
        }
        .offset(x: x)
        .animation(active ? nil : spring, value: x)
        .zIndex(page?.id == raised && page != nil ? 1 : 0)
      }
    }
    .frame(width: CGFloat(count + 1) * 28, height: 36, alignment: .leading)
    .contentShape(Rectangle())
    .highPriorityGesture(
      DragGesture(minimumDistance: 3)
        .updating($dragging) { _, dragging, _ in dragging = true }
        .onChanged { value in
          guard !cancelled else { return }
          if drag == nil {
            let index = Int(floor(value.startLocation.x / 28))
            guard index > 0, index <= count else { return }
            let page = favorites.pages[index - 1]
            drag = (page.id, index, CGFloat(index) * 28)
            raised = page.id
            sorting = true
            hovered = nil
            tooltip = page.info?.posterURL == nil ? nil : page.id
          }
          if let drag {
            self.drag?.x = min(
              max(CGFloat(drag.index) * 28 + value.translation.width, 28), CGFloat(count) * 28)
          }
        }
        .onEnded { value in
          if let drag, let index = favorites.pages.firstIndex(where: { $0.id == drag.id }) {
            let target =
              min(
                max(Int((CGFloat(drag.index) + value.translation.width / 28).rounded()), 1), count)
              - 1
            if index != target {
              favorites.pages.move(
                fromOffsets: IndexSet(integer: index), toOffset: target + (target > index ? 1 : 0))
            }
          }
          drag = nil
          sorting = false
          if !inside { tooltip = nil }
        }
    )
    .onHover { active in
      inside = active
      if !active, drag == nil {
        hovered = nil
        tooltip = nil
      }
    }
    .onChange(of: dragging) {
      if !dragging {
        if drag != nil { tooltip = nil }
        drag = nil
        sorting = false
        cancelled = false
      }
    }
    .onChange(of: favorites.pages.map(\.id)) { if drag != nil { cancelDrag() } }
    .onChange(of: scenePhase) { if scenePhase != .active { cancelDrag() } }
    .onExitCommand { cancelDrag() }
    .onDisappear { sorting = false }
    .task(id: hovered) {
      guard let hovered, tooltip == nil else { return }
      do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
      guard self.hovered == hovered else { return }
      tooltip = hovered
    }
  }

  private func cancelDrag() {
    cancelled = dragging
    drag = nil
    sorting = false
    hovered = nil
    tooltip = nil
  }
}
