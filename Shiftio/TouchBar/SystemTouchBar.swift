import AppKit

/// Mirrors the visible ring on the Touch Bar so actions can be tapped while a file is being dragged.
/// Without this a background (menubar) app has no Touch Bar content at all.
@MainActor
final class SystemTouchBar: NSObject, NSTouchBarDelegate {
    var onSelect: (any FileAction) -> Void = { _ in }
    var onNextRing: () -> Void = {}
    var tint: NSColor = .systemOrange

    private static let presentSelector = Selector(("presentSystemModalTouchBar:placement:systemTrayItemIdentifier:"))
    private static let nextRingID = NSTouchBarItem.Identifier("com.playgocorp.shiftio.touchbar.next")
    private static let actionPrefix = "com.playgocorp.shiftio.touchbar.action."

    private var touchBar: NSTouchBar?
    private var items: [String: RingItem] = [:]
    private var ringName = ""

    private var isSupported: Bool { NSTouchBar.responds(to: Self.presentSelector) }

    func present(_ ring: ResolvedRing?, ringCount: Int) {
        dismiss()
        guard isSupported, let ring else { return }

        let ringItems = [ring.center].compactMap { $0 } + ring.segments
        items = Dictionary(uniqueKeysWithValues: ringItems.map { ($0.id, $0) })
        ringName = ring.name

        var identifiers: [NSTouchBarItem.Identifier] = []
        if ringCount > 1 { identifiers.append(Self.nextRingID) }
        identifiers.append(contentsOf: ringItems.map { NSTouchBarItem.Identifier(Self.actionPrefix + $0.id) })

        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = identifiers
        touchBar = bar
        NSTouchBar.presentSystemModalTouchBar(bar, placement: 1, systemTrayItemIdentifier: nil)
    }

    func dismiss() {
        guard let touchBar else { return }
        if isSupported { NSTouchBar.dismissSystemModalTouchBar(touchBar) }
        self.touchBar = nil
    }

    // MARK: NSTouchBarDelegate

    nonisolated func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier)
        -> NSTouchBarItem? {
        MainActor.assumeIsolated { () -> NSTouchBarItem? in
            let touchBarItem = NSCustomTouchBarItem(identifier: identifier)
            if identifier == Self.nextRingID {
                let button = NSButton(title: ringName, image: NSImage(systemSymbolName: "shift", accessibilityDescription: nil)!,
                                      target: self, action: #selector(nextRingTapped))
                button.imagePosition = .imageLeading
                touchBarItem.view = button
                return touchBarItem
            }
            let id = String(identifier.rawValue.dropFirst(Self.actionPrefix.count))
            guard let ringItem = items[id] else { return nil }

            let symbol = ringItem.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
            let button = NSButton(title: ringItem.title.uppercased(), image: symbol ?? NSImage(),
                                  target: self, action: #selector(actionTapped(_:)))
            button.imagePosition = symbol == nil ? .noImage : .imageLeading
            button.identifier = NSUserInterfaceItemIdentifier(id)
            button.bezelColor = tint
            touchBarItem.view = button
            return touchBarItem
        }
    }

    @objc private func actionTapped(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let item = items[id] else { return }
        onSelect(item.action)
    }

    @objc private func nextRingTapped() { onNextRing() }
}
