import AppKit
import SwiftUI

struct SubtitleSlider: View {
  @Binding var value: Double
  let range: ClosedRange<Double>
  @State private var hovered = false
  @State private var editing = false

  var body: some View {
    Slider(
      value: Binding(get: { value }, set: { value = $0.rounded() }), in: range,
      onEditingChanged: { editing = $0 }
    )
    .controlSize(.small)
    .sliderThumbVisibility(hovered || editing ? .visible : .hidden)
    .contentShape(Rectangle())
    .onHover { hovered = $0 }
  }
}

struct SeekSlider: NSViewRepresentable {
  @Binding var value: Double
  let duration: Double
  let enabled: Bool
  let showsSavedPosition: Bool
  var editingChanged: (Bool) -> Void

  func makeCoordinator() -> SliderCoordinator { SliderCoordinator(value: $value) }

  func makeNSView(context: Context) -> Control {
    let slider = Control(
      value: value, minValue: 0, maxValue: duration, target: context.coordinator,
      action: #selector(SliderCoordinator.changed(_:)))
    slider.isContinuous = true
    slider.controlSize = .mini
    slider.trackFillColor = .white
    slider.setAccessibilityLabel("Playback Position")
    return slider
  }

  func updateNSView(_ slider: Control, context: Context) {
    context.coordinator.value = $value
    slider.editingChanged = editingChanged
    slider.readOnly = showsSavedPosition
    slider.maxValue = duration
    // AppKit fades the track fill when a disabled slider becomes enabled.
    slider.isEnabled = enabled || showsSavedPosition
    if !slider.scrubbing && slider.doubleValue != value { slider.doubleValue = value }
  }

  final class Control: NSSlider {
    var editingChanged: ((Bool) -> Void)?
    var scrubbing = false
    var readOnly = false

    override var acceptsFirstResponder: Bool { !readOnly && super.acceptsFirstResponder }

    override func keyDown(with event: NSEvent) {
      if readOnly { nextResponder?.keyDown(with: event) } else { super.keyDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
      guard isEnabled, !readOnly else { return }
      scrubbing = true
      editingChanged?(true)
      super.mouseDown(with: event)
      scrubbing = false
      editingChanged?(false)
    }
  }
}

struct VolumeSlider: NSViewRepresentable {
  @Binding var value: Double

  func makeCoordinator() -> SliderCoordinator { SliderCoordinator(value: $value) }

  func makeNSView(context: Context) -> NSSlider {
    let slider = NSSlider(
      value: value, minValue: 0, maxValue: 1, target: context.coordinator,
      action: #selector(SliderCoordinator.changed(_:)))
    slider.isVertical = true
    slider.isContinuous = true
    slider.controlSize = .small
    slider.appearance = NSAppearance(named: .darkAqua)
    slider.trackFillColor = .white
    slider.setAccessibilityLabel("Volume")
    return slider
  }

  func updateNSView(_ slider: NSSlider, context: Context) {
    context.coordinator.value = $value
    if slider.doubleValue != value { slider.doubleValue = value }
  }
}

@MainActor final class SliderCoordinator: NSObject {
  var value: Binding<Double>

  init(value: Binding<Double>) { self.value = value }

  @objc func changed(_ slider: NSSlider) { value.wrappedValue = slider.doubleValue }
}
