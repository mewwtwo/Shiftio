import AppKit
import SwiftUI

/// The trackpad offers only three taps, and the lightest ("alignment") is easy to miss. Hover uses the firmer
/// "level change", and choosing something adds a second tap right after the first so it clearly registers.
enum Haptics {
    private static var performer: NSHapticFeedbackPerformer { NSHapticFeedbackManager.defaultPerformer }

    static func open() { performer.perform(.levelChange, performanceTime: .now) }
    static func hover() { performer.perform(.levelChange, performanceTime: .now) }
    static func select() {
        performer.perform(.generic, performanceTime: .now)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { performer.perform(.levelChange, performanceTime: .now) }
    }
}

/// A panel that can take key focus (for Esc on the control ring) without activating the app.
private final class RingPanel: ActiveLookPanel {}

/// Floating, non-activating panel that hosts the ring and receives the drop.
@MainActor
final class RadialPanelController {
    let state = RadialState()
    /// Resolves rings for dragged files; empty result means nothing to show.
    var ringsForFiles: ([URL]) -> [ResolvedRing] = { _ in [] }
    var onDrop: (_ action: any FileAction, _ files: [URL]) -> Void = { _, _ in }
    /// Called whenever the visible ring changes (shown, switched) and with nil when hidden.
    var onRingChange: (_ ring: ResolvedRing?, _ ringCount: Int) -> Void = { _, _ in }

    /// Files the ring was opened for, once known.
    var currentFiles: [URL]? { files }
    /// A system-controls ring (⌘⇧) is open: no files, pointer-driven.
    private(set) var isControlMode = false
    /// Everything chosen on a control ring goes through this: AppState opens a tile's options, runs an option,
    /// or steps back.
    var onControlSelect: (any FileAction) -> Void = { _ in }
    /// The rings underneath the one on screen (a tile's options sit on top of the tiles).
    private var controlStack: [ResolvedRing] = []
    /// The user's custom names and icons, looked up by item id (so folders and options can be restyled too).
    var itemStyles: () -> [String: ItemStyle] = { [:] }
    /// The music player above a pop-up ring.
    let nowPlaying = NowPlayingPanelController()
    var nowPlayingEnabled: () -> Bool = { true }
    private var outsideClickMonitor: Any?
    private var hasRecentred = false
    private var loggedKeyState = false

    private var panel: NSPanel?
    private var observers: [NSObjectProtocol] = []
    /// Where the ring panel opened, so it can be moved down for the player and brought back.
    private var ringBaseOrigin = NSPoint.zero

    /// Gives way to the player: the ring slides `dy` (negative is down) from where it opened.
    func shiftRing(by dy: CGFloat) {
        guard isControlMode, let panel else { return }
        let target = NSPoint(x: ringBaseOrigin.x, y: ringBaseOrigin.y + dy)
        guard panel.frame.origin != target else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            // Only the frame animates on a window; its origin alone does not.
            panel.animator().setFrame(NSRect(origin: target, size: panel.frame.size), display: true)
        }
    }

    init() {
        // The panels belong to every desktop, so switching to another desktop or screen would carry them along. They close instead.
        let close: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state.isVisible || self.isControlMode || self.isPlayerOnly else { return }
                self.hide()
            }
        }
        observers = [
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil,
                                                              queue: .main, using: close),
            NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                                   queue: .main, using: close),
        ]
    }

    private var dropView: RadialDropView?
    private var files: [URL]?
    private var hideWork: DispatchWorkItem?
    private var shownAt = Date.distantPast
    /// Selection stays off until the pointer has been inside the hole once, so a ring that opens
    /// under the cursor can never pick an action by accident.
    private var armed = false

    /// `files == nil` → show an empty ring and fill it when the drag enters the panel.
    func show(files: [URL]?, at location: NSPoint, appearance: Appearance) {
        hideWork?.cancel()
        state.appearance = appearance
        armed = false
        hasRecentred = false
        loggedKeyState = false
        shownAt = .now
        isControlMode = false
        self.files = files
        var resolved: [ResolvedRing] = []
        if let files {
            resolved = ringsForFiles(files)
            guard !resolved.isEmpty else { return }
        }

        let panel = self.panel ?? makePanel()
        layout(panel, around: location)
        panel.orderFrontRegardless()
        // Liquid Glass draws flat and dim in a window that isn't key; the panel takes key status (without
        // activating the app) so the ring looks the same as the control ring does.
        panel.makeKey()
        present(rings: resolved)
        DebugLog.write("ring shown: frame=\(panel.frame) segments=\(resolved.first?.segments.map(\.title) ?? []) files=\(files?.count ?? -1)")
        Haptics.open()
    }

    /// Opens the ring of system controls around the pointer.
    func showControl(rings: [ResolvedRing], at location: NSPoint, appearance: Appearance) {
        guard !rings.isEmpty else { return }
        controlRings = rings
        hideWork?.cancel()
        state.appearance = appearance
        isControlMode = true
        controlStack = []
        files = nil
        armed = true
        shownAt = .now

        let panel = self.panel ?? makePanel()
        panel.acceptsMouseMovedEvents = true
        layout(panel, around: location)
        panel.orderFrontRegardless()
        // Key (without activating the app) so Esc works; a click anywhere else on screen dismisses the ring.
        panel.makeKey()
        panel.makeFirstResponder(dropView)
        installOutsideClickMonitor()
        present(rings: rings)
        Haptics.open()
        nowPlaying.service.onDismiss = { [weak self] in self?.hide() }
        nowPlaying.onEscape = { [weak self] in self?.escapePressed() }
        nowPlaying.service.onDetach = { [weak self] in self?.togglePlayerOnly() }
        nowPlaying.service.onPinChange = { [weak self] pinned in self?.playerPinChanged(pinned) }
        nowPlaying.onRingShift = { [weak self] dy in self?.shiftRing(by: dy) }
        ringBaseOrigin = panel.frame.origin
        if nowPlayingEnabled(), !nowPlaying.isPinned {
            let geometry = state.geometry
            let ringTop = panel.frame.maxY - (geometry.ringCenter.y - geometry.outerRadius)
            let ringBottom = panel.frame.maxY - (geometry.ringCenter.y + geometry.outerRadius)
            nowPlaying.show(ringFrame: panel.frame, ringTop: ringTop, ringBottom: ringBottom, appearance: appearance)
        }
    }

    /// Shows a tile's options as a second ring in the same place; the centre becomes a "back" button.
    func pushControl(_ tile: ControlAction) { pushControl(tile, children: tile.children) }

    func pushControl(_ tile: ControlAction, children: [ControlAction]) {
        guard isControlMode, let current = state.ring else { return }
        let styles = itemStyles()
        let items = children.map { child -> RingItem in
            let isOn = child.state()
            var item = RingItem(action: child, title: child.title, symbol: child.displaySymbol(isOn: isOn), isOn: isOn,
                                emoji: nil, image: child.image)
            guard let style = styles[child.id] else { return item }
            if let title = style.title, !title.isEmpty { item = RingItem(action: child, title: title, symbol: item.symbol, isOn: isOn, emoji: item.emoji, image: item.image) }
            // A glyph chosen for a folder is printed on the folder icon instead of replacing it.
            if child.id.hasPrefix("folder-"), let icon = style.icon {
                let folder = FolderPins.shared.items.first { "folder-" + $0.id == child.id }
                let base = folder.map(FolderIcon.baseIcon(for:)) ?? NSWorkspace.shared.icon(for: .folder)
                return RingItem(action: child, title: item.title, symbol: nil, isOn: isOn, emoji: nil,
                                image: FolderIcon.make(base: base, icon: icon))
            }
            switch style.icon {
            case .symbol(let name)?: item = RingItem(action: child, title: item.title, symbol: name, isOn: isOn, emoji: nil, image: nil)
            case .emoji(let value)?: item = RingItem(action: child, title: item.title, symbol: nil, isOn: isOn, emoji: value, image: nil)
            case .image(let file)?: item = RingItem(action: child, title: item.title, symbol: nil, isOn: isOn, emoji: nil, image: IconStore.load(file))
            case nil: break
            }
            return item
        }
        let back = ControlAction(id: ControlAction.backID, title: "‹ \(tile.title)", symbol: nil)
        let ring = ResolvedRing(name: tile.title, center: RingItem(action: back, title: back.title, symbol: nil, isOn: nil),
                                segments: items)
        controlStack.append(current)
        state.hover = nil
        state.rings = [ring]
        onRingChange(state.ring, state.rings.count)
        Haptics.open()
    }

    func popControl() {
        guard let previous = controlStack.popLast() else { return hide() }
        state.hover = nil
        state.rings = [previous]
        onRingChange(state.ring, state.rings.count)
    }

    /// Marks what was just chosen so the ring can play its "picked" animation.
    func commitHovered() {
        if let hover = state.hover { state.committed = hover }
    }

    /// ⌘⇧ was let go. On the tiles it opens or runs whatever is under the pointer; with a tile's options already
    /// open the ring simply stays, waiting for a click.
    func releaseControl() {
        // Let go over the player: it stays, so its buttons can be clicked. Esc or a click elsewhere closes it.
        if isControlMode, nowPlaying.isPointerInside {
            state.hover = nil
            return
        }
        guard isControlMode, controlStack.isEmpty else { return }
        if let hover = state.hover, let item = state.item(for: hover) {
            onControlSelect(item.action)
        } else {
            hide()
        }
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }

    func nextRing() {
        guard state.isVisible else { return }
        state.nextRing()
        onRingChange(state.ring, state.rings.count)
        Haptics.open()
    }

    /// The rings the control ring was opened with, to bring it back after the mini player.
    private var controlRings: [ResolvedRing] = []

    /// The pin was pressed. Pinned, the player ignores clicks elsewhere; unpinned with no ring open, the next click elsewhere closes it.
    private func playerPinChanged(_ pinned: Bool) {
        nowPlaying.setPinned(pinned)
        if !pinned, !isControlMode { installOutsideClickMonitor() }
    }

    /// The pip button: with the ring open it leaves only the player; pressed again it brings the ring back around the player.
    func togglePlayerOnly() {
        if isPlayerOnly { reattachRing() } else { detachPlayer() }
    }

    /// The ring comes back where it belongs under the player: centred on it, one gap below its lower edge.
    private func reattachRing() {
        guard isPlayerOnly, let player = nowPlaying.currentFrame, !controlRings.isEmpty else { return hide() }
        // Bringing the ring back puts the player above it again, so it is no longer pinned.
        if nowPlaying.isPinned {
            nowPlaying.service.isPinned = false
            nowPlaying.setPinned(false)
        }
        hideWork?.cancel()
        isPlayerOnly = false
        isControlMode = true
        controlStack = []
        files = nil
        armed = true
        shownAt = .now

        let geometry = state.geometry
        var ringTop = player.minY - NowPlayingPanelController.gap
        // A player low on the screen has no room under it: the ring takes the lowest place that fits and the player rises with it.
        let playerCentre = NSPoint(x: player.midX, y: player.midY)
        if let screen = (NSScreen.screens.first { $0.frame.contains(playerCentre) } ?? NSScreen.main)?.visibleFrame {
            ringTop = max(ringTop, screen.minY + 8 + 2 * geometry.outerRadius)
        }
        let centre = NSPoint(x: player.midX, y: ringTop - geometry.outerRadius)
        let panel = self.panel ?? makePanel()
        layout(panel, around: centre)
        ringBaseOrigin = panel.frame.origin
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(dropView)
        installOutsideClickMonitor()
        present(rings: controlRings)
        Haptics.open()
        // The panel may have been kept on screen, so the player is anchored to where the ring really is.
        let top = panel.frame.maxY - (geometry.ringCenter.y - geometry.outerRadius)
        let bottom = panel.frame.maxY - (geometry.ringCenter.y + geometry.outerRadius)
        nowPlaying.exitMiniMode(ringFrame: panel.frame, ringTop: top, ringBottom: bottom)
        // The ring took the keys above; the player takes them back, the same order as when both open together.
        nowPlaying.takeKeys()
        DispatchQueue.main.async { [weak self] in self?.nowPlaying.takeKeys() }
    }

    /// Only the player is left on screen, after its button was pressed. A click elsewhere or Esc closes it.
    private(set) var isPlayerOnly = false

    /// The ring goes and the mini player stays.
    func detachPlayer() {
        guard isControlMode else { return }
        hideWork?.cancel()
        state.isVisible = false
        isControlMode = false
        controlStack = []
        isPlayerOnly = true
        nowPlaying.enterMiniMode()
        onRingChange(nil, 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, !state.isVisible else { return }
            panel?.orderOut(nil)
        }
    }

    func hide(after delay: TimeInterval = 0) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            state.isVisible = false
            isControlMode = false
            controlStack = []
            removeOutsideClickMonitor()
            // A pinned player stays, and keeps working as the mini player.
            if !nowPlaying.isPinned { nowPlaying.hide() }
            isPlayerOnly = nowPlaying.isPinned
            onRingChange(nil, 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, !state.isVisible else { return }
                panel?.orderOut(nil)
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Puts new rings on screen from scratch. Resetting first means the segments are created fresh instead of
    /// morphing from whatever ring was shown before, which looked like uneven wedges during the opening animation.
    private func present(rings: [ResolvedRing]) {
        withTransaction(Transaction(animation: nil)) {
            state.isVisible = false
            state.hover = nil
            state.committed = nil
            state.ringIndex = 0
            state.rings = rings
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            state.isVisible = true
            onRingChange(state.ring, state.rings.count)
        }
    }

    private var isArmed: Bool { armed || Date.now.timeIntervalSince(shownAt) > 0.35 }

    private func makePanel() -> NSPanel {
        let panel = RingPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let container = NSView()
        let hosting = NSHostingView(rootView: RadialMenuView(state: state))
        hosting.autoresizingMask = [.width, .height]
        let dropView = RadialDropView()
        dropView.autoresizingMask = [.width, .height]
        dropView.delegate = self
        container.addSubview(hosting)
        container.addSubview(dropView)
        panel.contentView = container

        self.panel = panel
        self.dropView = dropView
        return panel
    }

    /// Places the panel so the ring centre sits under the cursor, kept on screen.
    private func layout(_ panel: NSPanel, around location: NSPoint) {
        let geometry = state.geometry
        let size = geometry.panelSize
        var origin = NSPoint(x: location.x - geometry.ringCenter.x,
                             y: location.y - (size.height - geometry.ringCenter.y))
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(location) }) {
            let bounds = screen.visibleFrame
            origin.x = min(max(origin.x, bounds.minX), bounds.maxX - size.width)
            origin.y = min(max(origin.y, bounds.minY), bounds.maxY - size.height)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.contentView?.subviews.forEach { $0.frame = NSRect(origin: .zero, size: size) }
    }
}

extension RadialPanelController: RadialDropViewDelegate {
    func dragUpdated(at point: CGPoint, files dropped: [URL]) -> Bool {
        if files == nil {
            // Drag pasteboard wasn't readable at trigger time; resolve now.
            files = dropped
            state.rings = ringsForFiles(dropped)
            if state.rings.isEmpty { hide() } else { onRingChange(state.ring, state.rings.count) }
        }
        if state.geometry.isInHole(point) { armed = true }
        // Entering the panel hands activity back to the drag's source, which would flatten the glass; take it back.
        // (`isKeyWindow` always says yes for the ring panel, so ask the app which window really has the keys.)
        if let panel, NSApp.keyWindow !== panel { panel.makeKey() }
        if !loggedKeyState {
            loggedKeyState = true
            DebugLog.write("on drag enter: key=\(panel?.isKeyWindow ?? false) appActive=\(NSApp.isActive)")
        }
        let hover = isArmed ? state.geometry.hit(point, keeping: state.hover).flatMap { state.item(for: $0) != nil ? $0 : nil } : nil
        if hover != state.hover {
            state.hover = hover
            DebugLog.write("hover: \(hover.flatMap { state.item(for: $0)?.title } ?? "none") armed=\(isArmed)")
            if hover != nil { Haptics.hover() }
        }
        return hover != nil
    }

    /// The system tells us where the dragged picture is once the drag enters the panel. If the ring
    /// opened a little off (the picture isn't always centred on the pointer), slide it onto the file, once.
    func recenter(onDragImage frame: NSRect) {
        guard !hasRecentred, !isControlMode, let panel, frame.width > 4 else { return }
        hasRecentred = true
        let geometry = state.geometry
        let wantedCentre = NSPoint(x: frame.midX, y: frame.midY)
        let currentCentre = NSPoint(x: panel.frame.minX + geometry.ringCenter.x,
                                    y: panel.frame.minY + (geometry.panelSize.height - geometry.ringCenter.y))
        let dx = wantedCentre.x - currentCentre.x, dy = wantedCentre.y - currentCentre.y
        // Only small corrections: grabbing an icon by its edge puts it a few dozen points off the pointer.
        // A bigger discrepancy means the reported frame can't be trusted, so the ring stays on the pointer.
        guard hypot(dx, dy) > 8, hypot(dx, dy) <= 60 else { return }
        DebugLog.write("recentre by (\(dx), \(dy)) onto drag image \(frame)")
        var target = panel.frame
        target.origin.x += dx
        target.origin.y += dy
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
        }
    }

    func dragExited() {
        state.hover = nil
    }

    func performDrop(at point: CGPoint, files dropped: [URL]) -> Bool {
        guard isArmed, let hover = state.geometry.hit(point), let item = state.item(for: hover) else {
            hide()
            return false
        }
        state.committed = hover
        DebugLog.write("drop on \(item.title) with \(dropped.map(\.lastPathComponent))")
        Haptics.select()
        onDrop(item.action, dropped)
        hide(after: 0.22)
        return true
    }
}

extension RadialPanelController {
    func escapePressed() {
        if isPlayerOnly { return nowPlaying.isPinned ? () : hide() }
        guard isControlMode else { return }
        if controlStack.isEmpty { hide() } else { popControl() }
    }

    func pointerMoved(to point: CGPoint) {
        guard isControlMode else { return }
        let hover = state.geometry.hit(point, keeping: state.hover).flatMap { state.item(for: $0) != nil ? $0 : nil }
        if hover != state.hover {
            state.hover = hover
            if hover != nil { Haptics.hover() }
        }
    }

    func pointerClicked(at point: CGPoint) {
        guard isControlMode, let hover = state.geometry.hit(point), let item = state.item(for: hover) else { return }
        Haptics.select()
        onControlSelect(item.action)
    }
}
