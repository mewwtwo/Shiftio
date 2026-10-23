import AppKit
import SwiftUI

/// Borderless glass panel. It can become key without activating the app, so buttons, text fields and
/// shortcuts work immediately even when the editor opens right after a drop on the (non-activating) ring.
private final class EditorWindow: ActiveLookPanel {}

@MainActor
final class EditorWindowController {
    static let shared = EditorWindowController()
    private var windows: [NSWindow] = []

    fileprivate func register(_ window: NSWindow) {
        windows.removeAll { !$0.isVisible }
        windows.append(window)
    }
    /// Set by the app before opening an editor, from Settings → Appearance → Glass.
    var glass = GlassSettings()

    func present<Content: View>(size: CGSize, @ViewBuilder content: (_ close: @escaping () -> Void) -> Content) {
        windows.removeAll { !$0.isVisible }

        // The window is at least as tall as its content wants. The content has fixed-height parts, and in a window that is a few points
        // too short it simply overflows, which cut the rounded corners flat at the top and bottom.
        let closer = Closer()
        let close: () -> Void = { closer.run() }
        let view = EditorEntrance { content(close) }
            .environment(\.glassSettings, glass)
            .keepsActiveLook()
        let ideal = NSHostingView(rootView: view.frame(width: size.width)).fittingSize.height
        let room = (NSScreen.main?.visibleFrame.height ?? 900) - 20
        let size = CGSize(width: size.width, height: min(max(size.height, ceil(ideal)), room))

        let window = EditorWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
        window.becomesKeyOnlyIfNeeded = false
        window.hidesOnDeactivate = false
        window.isOpaque = false
        window.backgroundColor = .clear
        // Soft system shadow like Quick Look's panel; it follows the rounded edge of the glass.
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        // Fade out, then close; the SwiftUI side handles the entrance.
        closer.run = { [weak window] in
            guard let window, window.isVisible else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                window.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated { window.close() }
            }
        }
        window.contentView = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        window.center()
        windows.append(window)

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

/// Lets the content be built before the window it will close exists.
@MainActor
private final class Closer {
    var run: () -> Void = {}
}

/// Key without activating the app, like the glass panels, but with a title bar's worth of window chrome.
private final class DocumentPanel: ActiveLookPanel {}

extension EditorWindowController {
    /// A resizable window with the standard traffic lights over transparent, full-size content.
    func presentDocument<Content: View>(title: String, size: CGSize, minSize: CGSize,
                                        @ViewBuilder content: (_ close: @escaping () -> Void) -> Content) {
        let window = DocumentPanel(contentRect: NSRect(origin: .zero, size: size),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                   backing: .buffered, defer: false)
        window.title = title
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = false
        window.minSize = minSize
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenPrimary]

        let close: () -> Void = { [weak window] in window?.close() }
        window.contentView = NSHostingView(rootView: content(close).environment(\.glassSettings, glass).keepsActiveLook())
        window.center()
        register(window)

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

/// Lets the header act as the window's drag handle (the window has no title bar).
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    /// Moves the window by following the pointer itself: the window's own background dragging does nothing in a borderless window.
    private final class DragView: NSView {
        private var startMouse = NSPoint.zero
        private var startOrigin = NSPoint.zero

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            startMouse = window?.convertPoint(toScreen: event.locationInWindow) ?? .zero
            startOrigin = window?.frame.origin ?? .zero
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window else { return }
            let now = window.convertPoint(toScreen: event.locationInWindow)
            window.setFrameOrigin(NSPoint(x: startOrigin.x + now.x - startMouse.x, y: startOrigin.y + now.y - startMouse.y))
        }
    }
}

/// Windows ease in with a small scale and fade, matching the system's own panels.
private struct EditorEntrance<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .scaleEffect(appeared || reduceMotion ? 1 : 0.95)
            .opacity(appeared ? 1 : 0)
            .onAppear { withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) { appeared = true } }
    }
}
