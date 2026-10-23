import AppKit

@MainActor
protocol RadialDropViewDelegate: AnyObject {
    /// Returns whether the point is over an action.
    func dragUpdated(at point: CGPoint, files: [URL]) -> Bool
    /// Frame of the dragged picture in screen coordinates, reported when the drag enters.
    func recenter(onDragImage frame: NSRect)
    func dragExited()
    func performDrop(at point: CGPoint, files: [URL]) -> Bool
    /// Plain pointer events, used by the ⌘⇧ ring (there is no drag in progress).
    func pointerMoved(to point: CGPoint)
    func pointerClicked(at point: CGPoint)
    func escapePressed()
}

/// Transparent overlay on top of the SwiftUI ring that acts as the drag destination.
final class RadialDropView: NSView {
    weak var delegate: RadialDropViewDelegate?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { delegate?.escapePressed() } else { super.keyDown(with: event) }
    }
    override func mouseMoved(with event: NSEvent) { delegate?.pointerMoved(to: convert(event.locationInWindow, from: nil)) }
    override func mouseDown(with event: NSEvent) { delegate?.pointerClicked(at: convert(event.locationInWindow, from: nil)) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        reportDragImage(sender)
        return update(sender)
    }

    /// Union of the dragged items' pictures, converted from this view's coordinates to the screen.
    private func reportDragImage(_ sender: NSDraggingInfo) {
        var union = NSRect.null
        sender.enumerateDraggingItems(options: [], for: self, classes: [NSURL.self], searchOptions: [:]) { item, _, _ in
            union = union.union(item.draggingFrame)
        }
        guard !union.isNull, let window else { return }
        delegate?.recenter(onDragImage: window.convertToScreen(convert(union, to: nil)))
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { delegate?.dragExited() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        delegate?.performDrop(at: location(of: sender), files: files(of: sender)) ?? false
    }

    private func update(_ sender: NSDraggingInfo) -> NSDragOperation {
        delegate?.dragUpdated(at: location(of: sender), files: files(of: sender)) == true ? .copy : []
    }

    private func location(of sender: NSDraggingInfo) -> CGPoint {
        convert(sender.draggingLocation, from: nil)
    }

    private func files(of sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                              options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}
