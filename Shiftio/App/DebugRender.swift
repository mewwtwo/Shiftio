import AppKit
import SwiftUI

/// `-ShiftioRenderTab <tab> <png path> <height>`: draws a settings pane at a height taller than the screen into a PNG, so
/// long panes can be checked in full (for translations and screenshots). Not used in normal runs.
@MainActor
enum DebugRender {
    static func handleLaunchArguments(app: AppState) {
        let arguments = ProcessInfo.processInfo.arguments
        // `-ShiftioAppearance light|dark` forces the app's appearance (for screenshots in both looks).
        if let index = arguments.firstIndex(of: "-ShiftioAppearance"), arguments.count > index + 1 {
            NSApp.appearance = NSAppearance(named: arguments[index + 1] == "light" ? .aqua : .darkAqua)
        }
        if let index = arguments.firstIndex(of: "-ShiftioBackdrop"), arguments.count > index + 3,
           let width = Double(arguments[index + 2]), let height = Double(arguments[index + 3]) {
            showBackdrop(floating: arguments[index + 1] == "floating", size: CGSize(width: width, height: height),
                         topRight: arguments.count > index + 4 && arguments[index + 4] == "topright",
                         theme: arguments.count > index + 5 ? arguments[index + 5] : "dark")
        }
        guard let index = arguments.firstIndex(of: "-ShiftioRenderTab"), arguments.count > index + 3,
              let tab = SettingsTab(rawValue: arguments[index + 1]), let height = Double(arguments[index + 3]) else { return }
        let path = arguments[index + 2]
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            render(AnyView(tab.content(app: app).keepsActiveLook()), size: CGSize(width: tab.size.width, height: height), to: path)
        }
    }

    private static var backdrop: NSWindow?

    /// `-ShiftioBackdrop floating|normal <width> <height> [center|topright] [dark|light|graphite|aurora]`: a plain gradient window in the middle of the screen, behind the
    /// app's own windows, so screenshots show Shiftio on a clean background instead of the desktop. "floating" also sits
    /// under the rings (which float above normal windows); "normal" sits under editors and settings.
    private static func showBackdrop(floating: Bool, size: CGSize, topRight: Bool, theme: String) {
        guard let frame = NSScreen.main?.frame else { return }
        // "topright" sits just under the menu bar at the right edge, where the menu bar popover opens.
        let origin = topRight ? NSPoint(x: frame.maxX - size.width, y: frame.maxY - 40 - size.height)
                              : NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2)
        let window = NSWindow(contentRect: NSRect(origin: origin, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.level = .floating
        // Dark: a deep violet to coral gradient. Light: a pearl white, like the glass icon.
        // "graphite" is a near-black, "aurora" a vivid teal to magenta gradient (for comparing glass styles).
        let colors: [Color]
        switch theme {
        case "light": colors = [Color(red: 0.95, green: 0.95, blue: 0.96), Color(red: 0.985, green: 0.985, blue: 0.99), Color(red: 0.91, green: 0.92, blue: 0.94)]
        case "graphite": colors = [Color(red: 0.06, green: 0.06, blue: 0.07), Color(red: 0.14, green: 0.14, blue: 0.16), Color(red: 0.08, green: 0.08, blue: 0.09)]
        case "aurora": colors = [Color(red: 0.08, green: 0.72, blue: 0.82), Color(red: 0.28, green: 0.32, blue: 0.92), Color(red: 0.88, green: 0.30, blue: 0.70), Color(red: 0.98, green: 0.58, blue: 0.30)]
        default: colors = [Color(red: 0.16, green: 0.17, blue: 0.36), Color(red: 0.42, green: 0.26, blue: 0.56), Color(red: 0.86, green: 0.50, blue: 0.46)]
        }
        window.contentView = NSHostingView(rootView: LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
        window.orderBack(nil)
        backdrop = window
        // Everything else the app opens goes above the backdrop, and above other apps' windows, so nothing from the real desktop
        // can overlap (or be blurred into) a screenshot.
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated {
                for other in NSApp.windows where other !== window && other.isVisible && other.level.rawValue < NSWindow.Level.floating.rawValue + 1 {
                    other.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
                }
            }
        }
    }

    private static func render(_ view: AnyView, size: CGSize, to path: String) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: -9000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFront(nil)
        window.setFrame(NSRect(x: 0, y: -9000, width: size.width, height: size.height), display: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
}
