import AppKit
import SwiftUI

@MainActor final class FramePreview: NSPanel {
  private var dismissing = false
  private var restingOrigin = CGPoint.zero
  private var scrollDistance: CGFloat = 0
  private var lastScrollTime = -Double.infinity
  private var scrollTask: Task<Void, Never>?

  init(url: URL, image: CGImage, screen: NSScreen?) {
    let aspect = CGFloat(image.width) / CGFloat(image.height)
    let size = CGSize(width: min(240, 180 * aspect), height: min(180, 240 / aspect))
    let bounds = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
    super.init(
      contentRect: CGRect(
        x: bounds.maxX - size.width - 24, y: bounds.minY + 24, width: size.width,
        height: size.height),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    restingOrigin = frame.origin
    title = "Saved Frame"
    level = .popUpMenu
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    backgroundColor = .clear
    isOpaque = false
    hasShadow = true
    contentView = NSHostingView(
      rootView: FrameThumbnail(
        url: url, image: image,
        dismiss: { [weak self] in self?.dismiss() }))
    orderFrontRegardless()
  }

  override func sendEvent(_ event: NSEvent) {
    guard event.type == .scrollWheel else {
      super.sendEvent(event)
      return
    }
    guard event.momentumPhase.isEmpty, !dismissing else { return }
    scrollTask?.cancel()
    if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
      resetPosition()
      return
    }
    if event.phase.contains(.began) || event.timestamp - lastScrollTime > 0.25 {
      scrollDistance = 0
    }
    lastScrollTime = event.timestamp
    if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
      scrollDistance = max(0, scrollDistance + event.scrollingDeltaX)
      setFrameOrigin(CGPoint(x: restingOrigin.x + scrollDistance, y: restingOrigin.y))
      alphaValue = 1 - min(0.5, scrollDistance / frame.width * 0.5)
      if scrollDistance > 40 { dismiss() }
    }
    if event.phase.isEmpty {
      scrollTask = Task { [weak self] in
        do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
        self?.resetPosition()
      }
    }
  }

  private func resetPosition() {
    guard !dismissing else { return }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      animator().setFrame(CGRect(origin: restingOrigin, size: frame.size), display: true)
      animator().alphaValue = 1
    }
  }

  private func dismiss() {
    guard !dismissing else { return }
    dismissing = true
    NSAnimationContext.runAnimationGroup { context in
      context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2
      context.timingFunction = CAMediaTimingFunction(name: .easeIn)
      animator().setFrame(
        CGRect(
          x: screen?.frame.maxX ?? frame.maxX, y: frame.minY, width: frame.width,
          height: frame.height), display: true)
      animator().alphaValue = 0
    } completionHandler: { [weak self] in
      Task { @MainActor in self?.close() }
    }
  }

  override func close() {
    dismissing = true
    scrollTask?.cancel()
    contentView = nil
    super.close()
  }
}

private struct FrameThumbnail: View {
  let url: URL
  let image: CGImage
  let dismiss: () -> Void
  @State private var hovered = false
  @State private var dragging = false

  var body: some View {
    Button {
      NSWorkspace.shared.open(url)
      dismiss()
    } label: {
      Image(decorative: image, scale: 1)
        .resizable().scaledToFit()
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
          RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.9), lineWidth: 3)
        }
    }
    .buttonStyle(.plain)
    .help(
      "Saved to \(url.deletingLastPathComponent().lastPathComponent) · Click to open, drag to share, or swipe right to dismiss"
    )
    .accessibilityLabel("Open Saved Frame")
    .draggable(SavedFrame(url: url))
    .dragConfiguration(.init(allowMove: false))
    .onDragSessionUpdated { session in
      switch session.phase {
      case .initial, .active: dragging = true
      case .ended(let operation):
        dragging = false
        if operation == .copy { dismiss() }
      default: break
      }
    }
    .contextMenu {
      Button("Show in Finder") {
        NSWorkspace.shared.activateFileViewerSelecting([url])
        dismiss()
      }
      Button("Dismiss") { dismiss() }
    }
    .onHover { hovered = $0 }
    .task(id: hovered || dragging) {
      guard !hovered, !dragging else { return }
      do { try await Task.sleep(for: .seconds(5)) } catch { return }
      dismiss()
    }
  }
}

private struct SavedFrame: Transferable {
  let url: URL

  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(exportedContentType: .png) { SentTransferredFile($0.url) }
    ProxyRepresentation(exporting: \.url)
  }
}
