import AppKit
import SwiftUI

/// A native slider that jumps back to its default value on double-click, with a short ease.
/// SwiftUI gestures don't reliably see clicks on a macOS `Slider`, so this wraps `NSSlider` directly.
struct ResettableSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double
    var step: Double?
    var tint: Color?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ResetNSSlider {
        let slider = ResetNSSlider()
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.onDoubleClick = { [weak coordinator = context.coordinator] in coordinator?.reset() }
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.toolTip = String(localized: "Double-click to reset")
        return slider
    }

    func updateNSView(_ slider: ResetNSSlider, context: Context) {
        context.coordinator.parent = self
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        if slider.doubleValue != value { slider.doubleValue = value }
        slider.trackFillColor = tint.map { NSColor($0) }
        slider.isEnabled = context.environment.isEnabled
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ResetNSSlider, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 120, height: nsView.intrinsicContentSize.height)
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: ResettableSlider
        private var timer: Timer?

        init(_ parent: ResettableSlider) { self.parent = parent }

        @objc func changed(_ sender: NSSlider) {
            timer?.invalidate()
            var value = sender.doubleValue
            if let step = parent.step { value = (value / step).rounded() * step }
            parent.value = value
        }

        func reset() {
            timer?.invalidate()
            let start = parent.value, end = parent.defaultValue
            guard start != end else { return }
            let began = Date.now
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.step(from: start, to: end, since: began) }
            }
        }

        private func step(from start: Double, to end: Double, since began: Date) {
            let progress = min(1, Date.now.timeIntervalSince(began) / 0.2)
            let eased = 1 - pow(1 - progress, 3)
            parent.value = start + (end - start) * eased
            if progress >= 1 {
                timer?.invalidate()
                timer = nil
            }
        }
    }
}

final class ResetNSSlider: NSSlider {
    var onDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
        } else {
            super.mouseDown(with: event)
        }
    }
}
