import AppKit
import SwiftUI
import Observation

struct RecentResult: Identifiable {
    let id = UUID()
    let date = Date()
    let actionTitle: String
    let sources: [URL]
    let outputs: [URL]
    let error: String?
}

@MainActor @Observable
final class AppState {
    let store = ConfigStore()
    private(set) var recents: [RecentResult] = []
    private(set) var runningCount = 0
    /// Set while Keep Awake is on: when it ends (nil = until turned off). Shown in the menu bar popover.
    private(set) var keepAwake: KeepAwakeStatus?

    struct KeepAwakeStatus: Equatable {
        var endsAt: Date?
    }
    /// A failure the user hasn't looked at yet; shown as a badge on the menubar icon.
    var hasUnseenError = false

    @ObservationIgnored private let monitor = DragShiftMonitor()
    @ObservationIgnored private let panel = RadialPanelController()
    @ObservationIgnored private let touchBar = SystemTouchBar()
    @ObservationIgnored private let chord = ChordMonitor()
    let speech = SpeechAssets()
    let components = ComponentInstaller()
    let appUsage = AppUsage.shared
    @ObservationIgnored private let setupWindow = SetupWindowController()
    @ObservationIgnored private let onboardingWindow = OnboardingWindowController()
    @ObservationIgnored private lazy var settingsWindow = SettingsWindowController(app: self)
    @ObservationIgnored private var menuPreviewPanel: NSPanel?

    var isEnabled: Bool {
        get { store.config.enabled }
        set { store.config.enabled = newValue; applyEnabled() }
    }

    init() {
        Self.adoptSettingsOfOldBundleID()
        panel.ringsForFiles = { [unowned self] in store.rings(for: $0) }
        panel.onDrop = { [unowned self] action, files in run(action, on: files) }

        panel.onRingChange = { [unowned self] ring, count in
            touchBar.tint = store.config.appearance.nsAccent
            touchBar.present(ring, ringCount: count)
        }
        touchBar.onNextRing = { [unowned self] in panel.nextRing() }
        touchBar.onSelect = { [unowned self] action in
            if panel.isControlMode { return handleControl(action) }
            guard let files = panel.currentFiles else { return }
            run(action, on: files)
            panel.hide()
        }

        // Hold ⌘⇧: ring of system controls around the pointer.
        panel.onControlSelect = { [unowned self] action in handleControl(action) }
        store.appUsage = appUsage
        panel.nowPlayingEnabled = { [unowned self] in store.config.nowPlayingEnabled }
        panel.itemStyles = { [unowned self] in store.config.itemStyles }
        chord.triggers = { [unowned self] in store.popupTriggers }
        chord.onShow = { [unowned self] id, location in
            guard let ring = store.popupRing(id: id) else { return }
            panel.showControl(rings: [ring], at: location, appearance: store.config.appearance)
        }
        chord.onRelease = { [unowned self] in panel.releaseControl() }
        chord.onCancel = { [unowned self] in panel.hide() }

        monitor.onShow = { [unowned self] files, location in
            panel.show(files: files, at: location, appearance: store.config.appearance)
        }
        monitor.onNextRing = { [unowned self] in panel.nextRing() }
        monitor.onModifierReleased = { [unowned self] in
            if store.config.hideOnModifierRelease { panel.hide() }
        }
        // Delay so a drop that ends the drag is still delivered to the panel.
        monitor.onDragEnded = { [unowned self] in panel.hide(after: 0.3) }

        applyEnabled()
        startComponentSetup()
        showOnboardingIfNeeded()
        NotificationCenter.default.addObserver(forName: .keepAwakeChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.keepAwake = KeepAwake.isActive ? KeepAwakeStatus(endsAt: KeepAwake.endsAt) : nil
            }
        }

        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-ShiftioPreview") { showPreview() }
        store.config.appearance.theme.apply()
        DebugRender.handleLaunchArguments(app: self)
        if arguments.contains("-ShiftioDemoKeepAwake") { keepAwake = KeepAwakeStatus(endsAt: nil) }
        if arguments.contains("-ShiftioDemoData") { seedDemoData() }
        if arguments.contains("-ShiftioPreviewPlayer") { panel.nowPlaying.service.useSample(expanded: arguments.contains("-ShiftioPlayerExpanded")) }
        if arguments.contains("-ShiftioPreviewControl") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
                let frame = NSScreen.main?.frame ?? .zero
                let index = UserDefaults.standard.integer(forKey: "ShiftioPopupIndex")
                let rings = store.config.rings[.system] ?? []
                let first = rings.indices.contains(index) ? store.popupRing(id: rings[index].id) : nil
                panel.showControl(rings: first.map { [$0] } ?? [], at: NSPoint(x: frame.midX, y: frame.midY),
                                  appearance: store.config.appearance)
                panel.state.hover = .segment(2)
                // `-ShiftioControlTile sys-keyboard` opens that tile's options (to look at the second ring).
                if let id = UserDefaults.standard.string(forKey: "ShiftioControlTile"),
                   let tile = ControlAction.tiles.first(where: { $0.id == id }) {
                    panel.pushControl(tile)
                    panel.state.hover = .segment(1)
                }
            }
        }
        if arguments.contains("-ShiftioOpenSettings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in openSettings() }
        }
        if arguments.contains("-ShiftioPreviewMenu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in showMenuPreview() }
        }
        // `-ShiftioEditor crop|add-bg|trim /path/to/file` opens an editor directly (for screenshots).
        if let index = arguments.firstIndex(of: "-ShiftioEditor"), arguments.count > index + 2,
           let action = ActionRegistry.action(arguments[index + 1]) {
            let url = URL(fileURLWithPath: arguments[index + 2])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in run(action, on: [url]) }
        }
    }

    /// The app used to be `com.shiftio.app`; its remembered choices (Compress settings and the like) live in that name's
    /// preferences, so they are copied across once.
    private static func adoptSettingsOfOldBundleID() {
        let defaults = UserDefaults.standard
        let flag = "adoptedComShiftioApp"
        guard !defaults.bool(forKey: flag) else { return }
        defaults.set(true, forKey: flag)
        guard let old = defaults.persistentDomain(forName: "com.shiftio.app") else { return }
        for (key, value) in old where defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
    }

    func openSettings() { settingsWindow.show() }

    func showOnboarding() { onboardingWindow.show(app: self) }

    /// First launch: a short tour of the two rings and the settings people change first.
    private func showOnboardingIfNeeded() {
        let defaults = UserDefaults.standard
        let force = ProcessInfo.processInfo.arguments.contains("-ShiftioShowOnboarding")
        guard force || !defaults.bool(forKey: "didShowOnboarding") else { return }
        defaults.set(true, forKey: "didShowOnboarding")
        // After the setup window (if any), so the tour ends up on top.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in showOnboarding() }
    }

    /// First launch: fetch what isn't inside the app (MP3 encoder, speech model) and say so in a small window.
    /// Later launches quietly retry anything that is still missing.
    private func startComponentSetup() {
        components.refresh()
        speech.prepareInBackground()
        let needsDownload = components.mp3 == .missing
        Task { await components.installMissing() }

        let defaults = UserDefaults.standard
        let force = ProcessInfo.processInfo.arguments.contains("-ShiftioShowSetup")
        if force || (needsDownload && !defaults.bool(forKey: "didShowSetup")) {
            defaults.set(true, forKey: "didShowSetup")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
                setupWindow.show(components: components, speech: speech)
            }
        }
    }

    /// Forgets the list of recent results. Files on disk are untouched.
    func clearRecents() {
        withAnimation(.smooth(duration: 0.25)) { recents.removeAll() }
        hasUnseenError = false
    }

    /// `-ShiftioPreviewMenu`: shows the menubar popover content in a plain panel (for screenshots).
    private func showMenuPreview() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 400), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        let hosting = NSHostingView(rootView: MenuBarView(app: self)
            .background(.regularMaterial, in: .rect(cornerRadius: 16, style: .continuous)))
        panel.contentView = hosting
        let size = hosting.fittingSize
        let screen = NSScreen.main?.visibleFrame ?? .zero
        panel.setFrame(NSRect(x: screen.maxX - size.width - 40, y: screen.maxY - size.height - 6,
                              width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        menuPreviewPanel = panel
    }

    /// While the tutorial is open its own demo rings answer the keys, so the real ones stay quiet.
    @ObservationIgnored private var tutorialActive = false

    func setTutorialActive(_ active: Bool) {
        tutorialActive = active
        if active { panel.hide() }
        applyEnabled()
    }

    func applyEnabled() {
        monitor.modifier = store.config.trigger.flag
        store.config.enabled && !tutorialActive ? monitor.start() : monitor.stop()
        chord.holdDelay = store.config.controlRingDelay
        store.config.enabled && store.config.controlRingEnabled && !tutorialActive ? chord.start() : chord.stop()
    }

    /// A tile opens its options as a second ring, "back" steps out, and anything else (an option, a shortcut,
    /// an app) runs and closes the ring.
    private func handleControl(_ action: any FileAction) {
        if let control = action as? ControlAction {
            if control.id == ControlAction.backID { return panel.popControl() }
            // Asked once: the options come from the system (Wi-Fi, Bluetooth…) and are slow enough to freeze the ring if read twice.
            let children = control.children
            if !children.isEmpty { return panel.pushControl(control, children: children) }
        }
        panel.commitHovered()
        // Screenshots and recordings must not catch the ring itself, so it goes first.
        if action.id.hasPrefix("shot-") || action.id == "record-screen" { panel.hide() }
        Task {
            do {
                _ = try await action.run([], options: store.config.actionOptions)
            } catch {
                record(RecentResult(actionTitle: action.title, sources: [], outputs: [], error: error.localizedDescription))
            }
            panel.hide(after: 0.2)
        }
    }

    func run(_ action: any FileAction, on files: [URL]) {
        if !(action is ControlAction) { ToolUsage.shared.record(action.id) }
        if let editor = action as? any EditorAction {
            // Editors follow the system accent colour; the accent setting belongs to the rings.
            let tint = Color(nsColor: .controlAccentColor)
            EditorWindowController.shared.glass = store.config.appearance.glass
            if editor.handlesBatch {
                editor.presentBatch(files, tint: tint) { [self] sources, result in
                    switch result {
                    case .success(let outputs): complete(action.title, sources: sources, outputs: outputs)
                    case .failure(let error): complete(action.title, sources: sources, error: error.localizedDescription)
                    }
                }
                return
            }
            for url in files {
                editor.present(url, tint: tint) { [self] result in
                    switch result {
                    case .success(let outputs): complete(action.title, sources: [url], outputs: outputs)
                    case .failure(let error): complete(action.title, sources: [url], error: error.localizedDescription)
                    }
                }
            }
            return
        }
        runningCount += 1
        Task {
            defer { runningCount -= 1 }
            do {
                let outputs = try await action.run(files, options: store.config.actionOptions)
                record(RecentResult(actionTitle: action.title, sources: files, outputs: outputs, error: nil))
                if store.config.revealInFinder, !outputs.isEmpty {
                    NSWorkspace.shared.activateFileViewerSelecting(outputs)
                }
            } catch {
                record(RecentResult(actionTitle: action.title, sources: files, outputs: [],
                                    error: error.localizedDescription))
            }
        }
    }

    private func complete(_ title: String, sources: [URL], outputs: [URL] = [], error: String? = nil) {
        record(RecentResult(actionTitle: title, sources: sources, outputs: outputs, error: error))
        if error == nil, store.config.revealInFinder, !outputs.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(outputs)
        }
    }

    private func record(_ result: RecentResult) {
        recents.insert(result, at: 0)
        recents = Array(recents.prefix(20))
        if result.error != nil { hasUnseenError = true }
    }

    private func seedDemoData() {
        if let demo = UserDefaults.standard.string(forKey: "ShiftioDemoFile") {
            let url = URL(fileURLWithPath: demo)
            recents = [RecentResult(actionTitle: "Remove BG", sources: [url], outputs: [url], error: nil)]
            try? KeepAwake.start(seconds: 3600)
            return
        }
        let docs = URL(fileURLWithPath: "/tmp/Page 001.pdf")
        recents = [
            RecentResult(actionTitle: "JPG", sources: [docs], outputs: [URL(fileURLWithPath: "/tmp/Page 001.jpg")], error: nil),
            RecentResult(actionTitle: "Compress", sources: [docs], outputs: [URL(fileURLWithPath: "/tmp/tangerine tree compressed.png")], error: nil),
            RecentResult(actionTitle: "Transcribe", sources: [docs], outputs: [], error: "No speech in interview.mov"),
        ]
    }

    /// `-ShiftioPreview` launch argument: show the ring for a sample PDF at screen centre (for screenshots).
    private func showPreview() {
        let defaults = UserDefaults.standard
        // `-ShiftioCategory image -ShiftioRing 1 -ShiftioDiameter 260` pick what the preview shows.
        let category = defaults.string(forKey: "ShiftioCategory").flatMap(FileCategory.init(rawValue:)) ?? .pdf
        let sample = URL(fileURLWithPath: "/tmp/Preview.pdf")
        let rings = (store.config.rings[category] ?? []).compactMap { ResolvedRing($0) { $0.accepts(category.sampleType) } }
        panel.ringsForFiles = { _ in rings }
        let frame = NSScreen.main?.frame ?? .zero
        var appearance = store.config.appearance
        // `-ShiftioGlass clear|frosted|solid` previews a glass style without touching saved settings.
        if let name = UserDefaults.standard.string(forKey: "ShiftioGlass"), let style = GlassStyle(rawValue: name) {
            appearance.glassStyle = style
        }
        if defaults.double(forKey: "ShiftioDiameter") > 0 { appearance.diameter = defaults.double(forKey: "ShiftioDiameter") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            panel.show(files: [sample], at: NSPoint(x: frame.midX, y: frame.midY), appearance: appearance)
            panel.state.ringIndex = min(defaults.integer(forKey: "ShiftioRing"), max(0, rings.count - 1))
            panel.state.hover = .segment(1)
            // `-ShiftioAutoSwitch` flips to the next ring after a moment (to capture the transition).
            if UserDefaults.standard.bool(forKey: "ShiftioAutoSwitch") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [self] in panel.nextRing() }
            }
        }
    }
}
