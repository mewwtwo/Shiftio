import AppKit
import SwiftUI

/// A regular preferences window with toolbar tabs. The SwiftUI `Settings` scene is unreliable in
/// menubar-only apps (it often opens behind other windows), and this gives a stable window.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let app: AppState
    private var window: NSWindow?
    private var current: SettingsTab
    private static let defaultSize = CGSize(width: 560, height: 720)
    /// Smallest the window may be made: the panes are scrolling forms, so they cope with any size above this.
    private static let minSize = CGSize(width: 520, height: 520)

    private static let defaultsKey = "settingsTab"

    init(app: AppState) {
        self.app = app
        current = UserDefaults.standard.string(forKey: Self.defaultsKey).flatMap(SettingsTab.init(rawValue:)) ?? .general
    }

    func show() {
        if window == nil { build() }
        // Without being the active app, controls are drawn in their grey, inactive look.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    private func build() {
        SettingsRoot.warmUp()
        let window = ActiveLookWindow(contentRect: .zero, styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.delegate = self
        window.title = current.title

        // One content view for all the panes: switching tabs animates inside it, and the window never changes size.
        let root = SettingsRoot(app: app, tab: current) { [weak self, weak window] picked in
            guard let self else { return }
            current = picked
            UserDefaults.standard.set(picked.rawValue, forKey: Self.defaultsKey)
            window?.title = picked.title
        }
        .keepsActiveLook()
        .frame(minWidth: Self.minSize.width, maxWidth: .infinity, minHeight: Self.minSize.height, maxHeight: .infinity)
        let host = NSHostingController(rootView: root)
        host.sizingOptions = []
        window.contentViewController = host
        window.contentMinSize = Self.minSize
        window.setContentSize(Self.defaultSize)
        window.center()
        self.window = window
    }
}
