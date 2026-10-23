import AppKit

/// Detects "hold this modifier combination for a moment" with no permissions: modifier state is polled, and the keyboard is
/// checked for other keys so ordinary shortcuts such as ⌘⇧4 or ⌘⇧T never open the ring.
@MainActor
final class ChordMonitor {
    /// Which pop-up ring (by id) to open, and where.
    var onShow: (_ ringID: UUID, _ location: NSPoint) -> Void = { _, _ in }
    /// The combinations to watch, re-read on every tick so Settings changes apply at once.
    var triggers: () -> [(id: UUID, trigger: ChordTrigger)] = { [] }
    /// The chord was let go while the ring was open.
    var onRelease: () -> Void = {}
    /// Another key was pressed with the ring open; close it without choosing anything.
    var onCancel: () -> Void = {}

    var holdDelay: TimeInterval = 0.3

    private enum Phase {
        case idle, pending(Date, UUID), showing(UUID), suppressed

        var isShowing: Bool {
            if case .showing = self { return true }
            return false
        }
    }
    private var phase = Phase.idle
    private var timer: Timer?

    /// Modifier key codes: ⌘ ⇧ ⌥ ⌃ fn and caps lock don't count as "another key".
    private static let modifierKeyCodes: Set<Int> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    /// With no modifier down there is nothing to time, so the check runs slowly and lets the system batch its wake-ups;
    /// once a modifier is held it speeds up so the hold delay is measured closely.
    private static let idleInterval = 1.0 / 12
    private static let activeInterval = 1.0 / 30
    private var interval = 0.0

    func start() {
        guard timer == nil else { return }
        schedule(Self.idleInterval)
    }

    private func schedule(_ seconds: TimeInterval) {
        timer?.invalidate()
        interval = seconds
        let timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = seconds * 0.4
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        interval = 0
        if case .showing = phase { onCancel() }
        phase = .idle
    }

    private func tick() {
        let flags = NSEvent.modifierFlags.intersection([.command, .shift, .option, .control])
        let wanted = flags.isEmpty && !phase.isShowing ? Self.idleInterval : Self.activeInterval
        if wanted != interval { schedule(wanted) }
        let match = triggers().first { flags == $0.trigger.flags }


        guard let match else {
            if case .showing = phase { onRelease() }
            phase = .idle
            return
        }

        switch phase {
        case .idle:
            // A drag has its own ring; don't start while a mouse button is down.
            if NSEvent.pressedMouseButtons == 0, !otherKeyDown { phase = .pending(.now, match.id) }
        case .pending(let since, let id):
            if NSEvent.pressedMouseButtons != 0 || otherKeyDown {
                phase = .suppressed
            } else if id != match.id {
                phase = .pending(.now, match.id)
            } else if Date.now.timeIntervalSince(since) >= holdDelay {
                phase = .showing(id)
                onShow(id, NSEvent.mouseLocation)
            }
        case .showing:
            if otherKeyDown {
                phase = .suppressed
                onCancel()
            }
        case .suppressed:
            break   // stays quiet until the keys are let go
        }
    }

    private var otherKeyDown: Bool {
        (0..<128).contains { !Self.modifierKeyCodes.contains($0) && CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0)) }
    }
}
