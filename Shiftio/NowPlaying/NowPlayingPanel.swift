import AppKit
import SwiftUI

/// Takes clicks without ever becoming the key window, so Esc and the ring keep working underneath.
private final class PlayerPanel: NSPanel {
    /// Esc goes to the ring, which would have had it if the player were not the key window.
    var onEscape: () -> Void = {}

    // Liquid Glass only draws fully (clear, lensing) in the key window, so the player takes the keys, without activating the app.
    /// A pinned player never takes the keys: it then always looks the way the system draws glass in a window without them, instead
    /// of changing every time focus moves to another app.
    var allowsKey = true
    override var canBecomeKey: Bool { allowsKey }
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { onEscape() }
}

/// Accepts the click that arrives while the panel is not the key window, which is always.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A second glass panel that sits right above the System ring while it is open. The player has priority for the space
/// above: when the lyrics or queue open and the screen has no more room there, the ring itself is moved down to make
/// space (and back when the player closes up again).
@MainActor
final class NowPlayingPanelController {
    let service = NowPlayingService()
    /// The ring's Esc handling, for when the player has the keys.
    var onEscape: () -> Void = {}
    /// Asks the ring to sit this far from where it opened (zero or negative: down).
    var onRingShift: (CGFloat) -> Void = { _ in }
    private var panel: NSPanel?
    private var hosting: FirstMouseHostingView<NowPlayingView>?
    private var isOn = false
    private var anchorX: CGFloat = 0
    /// Where the ring's upper edge was when it opened, and how far the ring may still move down.
    private var ringTop: CGFloat = 0
    private var maxShift: CGFloat = 0
    private var shift: CGFloat = 0
    private var bounds = NSRect.zero
    /// After the mini-player button: no ring any more, so the player stays where it is and grows downward from its top edge.
    private var isMini = false
    private var miniTop: CGFloat = 0
    private var miniCentre: CGFloat = 0
    /// Where a flung player rests, like the system's picture in picture: the four corners and the top centre.
    private enum Spot: CaseIterable {
        case topLeading, top, topTrailing, bottomLeading, bottomTrailing
        var isTop: Bool { self == .topLeading || self == .top || self == .topTrailing }
        var isBottom: Bool { !isTop }
    }
    private var spot: Spot?

    /// Space between the ring and the player.
    static let gap: CGFloat = 26
    /// How far from the screen's edges a resting player sits.
    private static let cornerInset: CGFloat = 14
    /// How far ahead of the pointer's speed the player is thrown (seconds of its movement), as with the system's own picture in picture.
    private static let throwTime: CGFloat = 0.25
    /// How close to a spot the player has to land to be drawn into it.
    private static let snapReach: CGFloat = 160

    var currentFrame: NSRect? { isOn ? panel?.frame : nil }
    var isPinned: Bool { service.isPinned }

    /// Whether the pointer is over the player, which keeps the ring open when the key combination is let go.
    var isPointerInside: Bool { isOn && panel?.isVisible == true && (panel?.frame.contains(NSEvent.mouseLocation) ?? false) }

    /// `ringTop` and `ringBottom` are the y of the ring's upper and lower edge in screen coordinates.
    func show(ringFrame: NSRect, ringTop: CGFloat, ringBottom: CGFloat, appearance: Appearance) {
        isOn = true
        isMini = false
        let centre = NSPoint(x: ringFrame.midX, y: ringFrame.midY)
        bounds = (NSScreen.screens.first { $0.frame.contains(centre) } ?? NSScreen.main)?.visibleFrame ?? ringFrame
        anchor(ringFrame: ringFrame, ringTop: ringTop, ringBottom: ringBottom)

        let view = NowPlayingView(service: service, appearance: appearance)
        if let hosting { hosting.rootView = view } else {
            let hosting = FirstMouseHostingView(rootView: view)
            self.hosting = hosting
            makePanel().contentView = hosting
        }
        service.onChange = { [weak self] in self?.update() }
        service.start()
        update()
        // The glass materializes on the next turn of the run loop, exactly when the ring's does.
        service.isShown = false
        DispatchQueue.main.async { [weak self] in
            guard let self, isOn else { return }
            service.isShown = true
        }
    }

    /// Where the player sits relative to the ring, and how much room the lists have.
    private func anchor(ringFrame: NSRect, ringTop: CGFloat, ringBottom: CGFloat) {
        self.ringTop = ringTop
        maxShift = max(0, ringBottom - bounds.minY - 8)
        shift = 0
        // The lists get as much height as the room above and the ring's room to move down allow, up to a comfortable size.
        let room = bounds.maxY - (ringTop + Self.gap) - 8 + maxShift
        service.paneHeight = min(170, max(70, room - 175))
        anchorX = ringFrame.midX
    }

    /// The ring is back: the player goes from keeping its own place to sitting above the ring again.
    func exitMiniMode(ringFrame: NSRect, ringTop: CGFloat, ringBottom: CGFloat) {
        isMini = false
        spot = nil
        service.isMini = false
        let centre = NSPoint(x: ringFrame.midX, y: ringFrame.midY)
        bounds = (NSScreen.screens.first { $0.frame.contains(centre) } ?? NSScreen.main)?.visibleFrame ?? ringFrame
        anchor(ringFrame: ringFrame, ringTop: ringTop, ringBottom: ringBottom)
        place()
    }

    /// The player takes the keys again, as it does when the ring first opens, so its glass draws fully active.
    func takeKeys() { panel?.makeKey() }

    /// The ring is gone; from now on the player keeps its own place.
    func enterMiniMode() {
        guard let panel, panel.isVisible else { return }
        isMini = true
        spot = nil
        service.isMini = true
        miniTop = panel.frame.maxY
        miniCentre = panel.frame.midX
    }

    /// A pinned player can be dragged by its background to wherever it is wanted.
    func setPinned(_ pinned: Bool) {
        panel?.isMovableByWindowBackground = pinned
        if let panel = panel as? PlayerPanel {
            panel.allowsKey = !pinned
            if pinned {
                // Gives up the keys it may hold by showing the window again without them.
                service.isKey = false
                panel.orderOut(nil)
                panel.orderFrontRegardless()
            }
        }
        // Pinned, the player belongs to the whole desktop: it is on every Space and over full-screen apps. (`.stationary` was tried and
        // made it slow to appear on a Space that holds a full-screen app.)
        panel?.collectionBehavior = pinned
            ? [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            : [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        if pinned, let panel {
            // From here on the player keeps the place it has, wherever it is moved to.
            isMini = true
            service.isMini = true
            miniTop = panel.frame.maxY
            miniCentre = panel.frame.midX
        }
    }

    /// Where the player's window sits at a resting spot, for a window of this size.
    private func origin(of spot: Spot, size: NSSize) -> NSPoint {
        let inset = Self.cornerInset
        let x: CGFloat
        switch spot {
        case .topLeading, .bottomLeading: x = bounds.minX + inset
        case .topTrailing, .bottomTrailing: x = bounds.maxX - size.width - inset
        case .top: x = bounds.midX - size.width / 2
        }
        let y = spot.isTop ? bounds.maxY - size.height - inset : bounds.minY + inset
        return NSPoint(x: x, y: y)
    }

    /// The pinned player was let go: it is thrown on with the speed it had and comes to rest at the spot nearest to where it would land.
    private func settleAfterDrag() {
        guard service.isPinned, let panel else { return }
        let frame = panel.frame
        let centre = NSPoint(x: frame.midX, y: frame.midY)
        bounds = (NSScreen.screens.first { $0.frame.contains(centre) } ?? NSScreen.main)?.visibleFrame ?? bounds
        let velocity = service.releaseVelocity
        let landing = NSPoint(x: centre.x + velocity.dx * Self.throwTime, y: centre.y + velocity.dy * Self.throwTime)
        let distances = Spot.allCases.map { spot -> (spot: Spot, distance: CGFloat) in
            let at = origin(of: spot, size: frame.size)
            return (spot, hypot(at.x + frame.width / 2 - landing.x, at.y + frame.height / 2 - landing.y))
        }
        // Only a throw that ends near a spot is drawn into it; anywhere else the player stays where it was let go.
        spot = distances.min { $0.distance < $1.distance }.flatMap { $0.distance < Self.snapReach ? $0.spot : nil }
        if let spot {
            let at = origin(of: spot, size: frame.size)
            miniTop = at.y + frame.height
            miniCentre = at.x + frame.width / 2
        } else {
            // Free of the spots, the throw still carries it on: it glides to where it would have landed.
            miniTop = landing.y + frame.height / 2
            miniCentre = landing.x
        }
        place()
    }

    func hide() {
        isOn = false
        isMini = false
        spot = nil
        service.isMini = false
        service.isPinned = false
        panel?.isMovableByWindowBackground = false
        panel?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        service.isShown = false
        service.stop()
        service.onChange = {}
        // Out after the glass has dematerialized, like the ring's panel.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, !isOn else { return }
            panel?.orderOut(nil)
        }
    }

    /// Shows the panel when there is something to show, sized to it. Opening the lyrics changes the content a moment after
    /// the state does, so the size is measured again on the next turn of the run loop.
    private func update() {
        place()
        DispatchQueue.main.async { [weak self] in self?.place() }
    }

    private func place() {
        guard isOn, let panel, let hosting, !service.isDragging else { return }
        guard service.hasContent else {
            panel.orderOut(nil)
            return
        }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0 else { return }

        if isMini {
            // The place the user chose (`miniTop`, `miniCentre`) is kept apart from where the window is drawn, so a player that was
            // pushed up by the lyrics goes back to it when they close. At a resting spot it stays there and grows away from the edge.
            var origin = NSPoint(x: miniCentre - size.width / 2, y: miniTop - size.height)
            if let spot { origin = self.origin(of: spot, size: size) }
            origin.x = min(max(origin.x, bounds.minX + 8), bounds.maxX - size.width - 8)
            origin.y = min(max(origin.y, bounds.minY + 8), bounds.maxY - size.height - 8)
            apply(NSRect(origin: origin, size: size), to: panel)
            return
        }

        // How much the player would stick out above the screen, and how much of that the ring can give way by.
        let deficit = max(0, ringTop + Self.gap + size.height - (bounds.maxY - 8))
        let wanted = min(deficit, maxShift)
        if wanted != shift {
            shift = wanted
            onRingShift(-shift)
        }

        var origin = NSPoint(x: anchorX - size.width / 2, y: ringTop - shift + Self.gap)
        origin.x = min(max(origin.x, bounds.minX + 8), bounds.maxX - size.width - 8)
        origin.y = min(origin.y, bounds.maxY - size.height - 8)
        apply(NSRect(origin: origin, size: size), to: panel)
    }

    private func apply(_ frame: NSRect, to panel: NSPanel) {
        guard panel.frame != frame else { return }
        if panel.isVisible && panel.frame.size != .zero {
            // Resizing (the lyrics opening, a longer title) follows the glass's own motion instead of jumping.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
        if !panel.isVisible { panel.orderFrontRegardless(); panel.makeKey() }
    }

    private func makePanel() -> NSPanel {
        let panel = PlayerPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.onEscape = { [weak self] in self?.onEscape() }
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        for (name, key) in [(NSWindow.didBecomeKeyNotification, true), (NSWindow.didResignKeyNotification, false)] {
            NotificationCenter.default.addObserver(forName: name, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.service.isKey = key }
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // Only the user's own dragging moves the chosen place; the panel's resizing moves the window too.
                guard let self, self.service.isPinned, self.service.isDragging, let panel = self.panel else { return }
                self.miniTop = panel.frame.maxY
                self.miniCentre = panel.frame.midX
            }
        }
        service.onDragEnd = { [weak self] in self?.settleAfterDrag() }
        self.panel = panel
        return panel
    }
}
