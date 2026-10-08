import AppKit
import SwiftUI

struct SeekSlider: NSViewRepresentable {
    @Binding var value: Double
    let duration: Double
    let enabled: Bool
    var editingChanged: (Bool) -> Void

    func makeCoordinator() -> SliderCoordinator { SliderCoordinator(value: $value) }

    func makeNSView(context: Context) -> Control {
        let slider = Control()
        slider.target = context.coordinator
        slider.action = #selector(SliderCoordinator.changed(_:))
        slider.isContinuous = true
        slider.controlSize = .mini
        slider.trackFillColor = .white
        slider.setAccessibilityLabel("Playback position")
        return slider
    }

    func updateNSView(_ slider: Control, context: Context) {
        context.coordinator.value = $value
        slider.editingChanged = editingChanged
        slider.maxValue = duration
        slider.isEnabled = enabled
        if !slider.scrubbing && slider.doubleValue != value { slider.doubleValue = value }
    }

    final class Control: NSSlider {
        var editingChanged: ((Bool) -> Void)?
        var scrubbing = false

        override func mouseDown(with event: NSEvent) {
            guard isEnabled else { return }
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
        let slider = NSSlider(value: value, minValue: 0, maxValue: 1, target: context.coordinator, action: #selector(SliderCoordinator.changed(_:)))
        slider.isVertical = true
        slider.isContinuous = true
        slider.controlSize = .small
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
