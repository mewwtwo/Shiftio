import AppKit

/// With `-ShiftioLog 1` appends a line per event to the file named by `-ShiftioLogFile` (default ~/Shiftio.log).
enum DebugLog {
    static func write(_ line: String) {
        guard UserDefaults.standard.bool(forKey: "ShiftioLog") else { return }
        let path = UserDefaults.standard.string(forKey: "ShiftioLogFile") ?? NSHomeDirectory() + "/Shiftio.log"
        let entry = "\(Date.now.formatted(.iso8601)) \(line)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            try? handle.close()
        } else {
            try? Data(entry.utf8).write(to: URL(fileURLWithPath: path))
        }
    }
}

/// Watches system-wide file drags and reports presses of the trigger key while one is in progress.
/// Uses only global mouse monitors and modifier polling, so no Accessibility permission is needed.
@MainActor
final class DragShiftMonitor {
    /// First press during a drag. `files` is nil when the drag pasteboard can't be read yet;
    /// the panel then picks the files up from the drop session.
    var onShow: (_ files: [URL]?, _ location: NSPoint) -> Void = { _, _ in }
    /// Every further press while the menu is shown.
    var onNextRing: () -> Void = {}
    var onModifierReleased: () -> Void = {}
    var onDragEnded: () -> Void = {}

    var modifier: NSEvent.ModifierFlags = .shift

    private var monitors: [Any] = []
    private var timer: Timer?
    private var baselineChangeCount = 0
    private var isShowing = false
    private var wasModifierDown = false

    func start() {
        guard monitors.isEmpty else { return }
        let down = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.baselineChangeCount = NSPasteboard(name: .drag).changeCount }
        }
        let dragged = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            MainActor.assumeIsolated { self?.dragMoved() }
        }
        monitors = [down, dragged].compactMap { $0 }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        finishDrag()
    }

    private func dragMoved() {
        guard timer == nil else { return }
        wasModifierDown = false
        // Polling keeps working while another app runs its drag loop and needs no input-monitoring permission.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard NSEvent.pressedMouseButtons & 1 != 0 else { return finishDrag() }

        let isDown = NSEvent.modifierFlags.contains(modifier)
        defer { wasModifierDown = isDown }

        if isDown && !wasModifierDown {
            if isShowing {
                onNextRing()
            } else if isFileDrag {
                isShowing = true
                // The ring opens at the pointer; once the drag enters the ring, the panel slides onto the picture itself.
                DebugLog.write("show: mouse=\(NSEvent.mouseLocation) files=\(draggedFiles?.map(\.lastPathComponent) ?? [])")
                onShow(draggedFiles, NSEvent.mouseLocation)
            }
        } else if !isDown && wasModifierDown && isShowing {
            onModifierReleased()
        }
    }

    private func finishDrag() {
        timer?.invalidate()
        timer = nil
        if isShowing {
            isShowing = false
            onDragEnded()
        }
    }

    private var isFileDrag: Bool {
        let pasteboard = NSPasteboard(name: .drag)
        return pasteboard.changeCount != baselineChangeCount && pasteboard.types?.contains(.fileURL) == true
    }

    private var draggedFiles: [URL]? {
        let urls = NSPasteboard(name: .drag).readObjects(forClasses: [NSURL.self],
                                                          options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls?.isEmpty == false ? urls : nil
    }
}
