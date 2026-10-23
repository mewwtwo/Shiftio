import AppKit
import SwiftUI

/// Glass and controls switch to a flat, grey look in windows that aren't key. Shiftio's windows keep the active look
/// whatever has the focus, so these report themselves as key and main for drawing (typing and shortcuts still follow
/// the real key window).
class ActiveLookWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

class ActiveLookPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

extension View {
    /// Controls inside the window keep their active look too.
    func keepsActiveLook() -> some View { environment(\.controlActiveState, .key) }
}
