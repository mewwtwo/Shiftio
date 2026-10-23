import AppKit
import CoreBluetooth
import SwiftUI

/// The first-launch tour: how the two rings work, then the few settings people most often want to change.
struct OnboardingView: View {
    @Bindable var app: AppState
    let openSettings: () -> Void
    let finish: () -> Void

    /// `-ShiftioOnboardingStep 2` opens the tour on that page (for screenshots).
    @State private var step = UserDefaults.standard.integer(forKey: "ShiftioOnboardingStep")
    @State private var keys = KeyWatcher()
    @State private var fileDone = false
    @State private var popupDone = false
    @AppStorage(SuggestedAppsMode.modeKey) private var suggestedMode = SuggestedAppsMode.mixed.rawValue
    @State private var forward = true
    private let steps = 4

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch step {
                case 0: fileRing
                case 1: popupRing
                case 2: permissions
                default: personalize
                }
            }
            .id(step)
            .transition(.asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                                    removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            HStack {
                Button("Back") { go(step - 1) }.opacity(step == 0 ? 0 : 1).disabled(step == 0)
                Spacer()
                HStack(spacing: 6) {
                    ForEach(0..<steps, id: \.self) { Circle().fill(.primary.opacity($0 == step ? 0.7 : 0.18)).frame(width: 6, height: 6) }
                }
                Spacer()
                if step < steps - 1 {
                    Button("Continue") { go(step + 1) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(!canContinue)
                        .help(canContinue ? "" : "Try it first")
                } else {
                    Button("Start Using Shiftio", action: finish).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 560, height: 630)
        .background { OnboardingBackground() }
        .onAppear { keys.start() }
        .onDisappear { keys.stop() }
    }

    /// The first two steps are practice: the tour waits until the key press has really been tried.
    private var canContinue: Bool {
        switch step {
        case 0: fileDone
        case 1: popupDone || !app.store.config.controlRingEnabled
        default: true
        }
    }

    private func go(_ next: Int) {
        guard next <= step || canContinue else { return }
        forward = next > step
        withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { step = min(max(next, 0), steps - 1) }
    }

    // MARK: Pages

    private var fileRing: some View {
        page(symbol: "app-icon", color: .orange, title: "Welcome to Shiftio",
             text: "Try it right here: press \(app.store.config.trigger.title), then drag the file onto an action.") {
            FileRingDemo(completed: $fileDone, keys: keys, triggerFlag: app.store.config.trigger.flag, triggerTitle: app.store.config.trigger.title)
                .frame(maxWidth: .infinity)
        }
    }

    private var popupRing: some View {
        page(symbol: "circle.hexagongrid.fill", color: .purple, title: "The pop-up ring",
             text: "System controls without leaving what you're doing. Hold the keys for a moment.") {
            @Bindable var store = app.store
            PopupRingDemo(completed: $popupDone, keys: keys, delay: store.config.controlRingDelay)
                .frame(maxWidth: .infinity)
                .opacity(store.config.controlRingEnabled ? 1 : 0.35)
                .allowsHitTesting(store.config.controlRingEnabled)
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Use the pop-up ring").font(.system(size: 13, weight: .medium))
                    Text("You can turn it off and keep only the file ring.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: $store.config.controlRingEnabled).labelsHidden().toggleStyle(.switch)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.primary.opacity(0.06), in: .rect(cornerRadius: 12, style: .continuous))
            .onChange(of: store.config.controlRingEnabled) { app.applyEnabled() }

            if store.config.controlRingEnabled {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Show the player").font(.system(size: 13, weight: .medium))
                        Text("What's playing in Music or Spotify, above the ring.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: $store.config.nowPlayingEnabled).labelsHidden().toggleStyle(.switch)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.primary.opacity(0.06), in: .rect(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private var permissions: some View {
        page(symbol: "lock.shield.fill", color: .green, title: "Permissions",
             text: "Shiftio only asks for what a feature needs, and only when you press Allow.") {
            PermissionsList(openSettings: openSettings)
        }
    }

    /// Whether the pop-up ring has the Recent apps tile (`sys-suggestedapps`); turning it off takes the tile out of every pop-up ring.
    private var suggestedInRing: Binding<Bool> {
        Binding(
            get: { (app.store.config.rings[.system] ?? []).contains { $0.segments.contains("sys-suggestedapps") } },
            set: { on in
                var rings = app.store.config.rings[.system] ?? []
                if on {
                    if !rings.isEmpty, !rings.contains(where: { $0.segments.contains("sys-suggestedapps") }) {
                        rings[0].segments.append("sys-suggestedapps")
                    }
                } else {
                    for index in rings.indices { rings[index].segments.removeAll { $0 == "sys-suggestedapps" } }
                }
                app.store.config.rings[.system] = rings
            })
    }

    private var personalize: some View {
        @Bindable var store = app.store
        return page(symbol: "slider.horizontal.3", color: .blue, title: "Make it yours",
             text: "You can change all of this later in Settings.") {
            VStack(spacing: 0) {
                row("Trigger key", detail: "Press it while dragging a file") {
                    Picker("", selection: $store.config.trigger) {
                        ForEach(TriggerModifier.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    .onChange(of: app.store.config.trigger) { app.applyEnabled() }
                }
                Divider()
                row("Reveal results in Finder", detail: "Select the new file when it's done") {
                    Toggle("", isOn: $store.config.revealInFinder).labelsHidden()
                }
                Divider()
                row("Recent tools ring first", detail: "The tools you use most, ahead of the rest") {
                    Toggle("", isOn: $store.config.recentRingEnabled).labelsHidden()
                }
                Divider()
                row("Recent & frequent apps", detail: "In the pop-up ring: apps you use lately or most") {
                    HStack(spacing: 8) {
                        if suggestedInRing.wrappedValue {
                            Picker("", selection: $suggestedMode) {
                                ForEach(SuggestedAppsMode.allCases) { Text($0.title).tag($0.rawValue) }
                            }
                            .labelsHidden().fixedSize()
                        }
                        Toggle("", isOn: suggestedInRing).labelsHidden()
                    }
                }
            }
            .padding(.horizontal, 14)
            .background(.primary.opacity(0.06), in: .rect(cornerRadius: 12, style: .continuous))

            OnboardingPinnedApps()

            Button("Open All Settings…", action: openSettings).padding(.top, 4)
        }
    }

    // MARK: Pieces

    private func page<Content: View>(symbol: String, color: Color, title: LocalizedStringKey, text: LocalizedStringKey,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 6) {
            if symbol == "app-icon" {
                Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                    .padding(.top, 24)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(color.gradient, in: .rect(cornerRadius: 16, style: .continuous))
                    .padding(.top, 28)
            }
            Text(title).font(.title.weight(.semibold)).multilineTextAlignment(.center).padding(.top, 6).padding(.horizontal, 32)
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 36).padding(.bottom, 14)
            VStack(alignment: .leading, spacing: 12) { content() }
                .padding(.horizontal, 36)
            Spacer(minLength: 0)
        }
    }

    private func tip(_ badge: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(badge)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .frame(width: 38, height: 28)
                .background(.primary.opacity(0.08), in: .rect(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func row<Control: View>(_ title: LocalizedStringKey, detail: LocalizedStringKey, @ViewBuilder control: () -> Control) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            control()
        }
        .padding(.vertical, 9)
    }
}

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private weak var app: AppState?

    func show(app: AppState) {
        self.app = app
        if window == nil {
            let window = ActiveLookWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isMovableByWindowBackground = true
            window.delegate = self
            window.title = String(localized: "Welcome to Shiftio")
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(
                rootView: OnboardingView(app: app, openSettings: { [weak window] in
                    window?.close()
                    app.openSettings()
                }, finish: { [weak window] in window?.close() }).keepsActiveLook())
            window.setContentSize(NSSize(width: 560, height: 630))
            self.window = window
        }
        centerOnScreen()
        app.setTutorialActive(true)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) { app?.setTutorialActive(false) }

    /// Exactly in the middle of the screen with the pointer (`NSWindow.center()` sits above the middle).
    private func centerOnScreen() {
        guard let window else { return }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2, y: frame.midY - window.frame.height / 2))
    }
}


// MARK: Background

/// A see-through window: the desktop blurred behind, with a soft tint so the text stays readable.
private struct OnboardingBackground: View {
    var body: some View {
        ZStack {
            BackdropBlur()
            LinearGradient(colors: [.orange.opacity(0.14), .purple.opacity(0.12), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .ignoresSafeArea()
    }
}

// MARK: Live keys

/// Which modifier keys are down right now, read from the window's own key events (no permission needed).
@MainActor @Observable
final class KeyWatcher {
    private(set) var flags: NSEvent.ModifierFlags = []
    @ObservationIgnored private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let flags = event.modifierFlags.intersection([.shift, .option, .control, .command])
            MainActor.assumeIsolated { self?.flags = flags }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        flags = []
    }

    func isDown(_ flag: NSEvent.ModifierFlags) -> Bool { flags.contains(flag) }
}

private struct KeyCap: View {
    let label: String
    let name: String
    let pressed: Bool

    var body: some View {
        VStack(spacing: 2) {
            Text(label).font(.system(size: 22, weight: .medium, design: .rounded))
            Text(name).font(.system(size: 10)).foregroundStyle(pressed ? .white.opacity(0.85) : .secondary)
        }
        .foregroundStyle(pressed ? .white : .primary)
        .frame(width: 74, height: 56)
        .background(pressed ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary.opacity(0.08)), in: .rect(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(pressed ? 0 : 0.18), radius: 0, y: pressed ? 0 : 3)
        .offset(y: pressed ? 3 : 0)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: pressed)
    }
}

/// A round tile of a demo ring.
private struct DemoTile: View {
    let symbol: String
    let title: String
    var lit = false

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 46, height: 46)
                .background(lit ? AnyShapeStyle(.tint) : AnyShapeStyle(.regularMaterial), in: .circle)
                .foregroundStyle(lit ? .white : .primary)
                .scaleEffect(lit ? 1.15 : 1)
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: lit)
    }
}

// MARK: Demos

/// Press the trigger key, then drag the sample file onto a tile of the ring.
private struct FileRingDemo: View {
    @Binding var completed: Bool
    let keys: KeyWatcher
    let triggerFlag: NSEvent.ModifierFlags
    let triggerTitle: String

    private struct Tile { let symbol: String; let title: String; let result: String }
    private let rings: [(name: String, tiles: [Tile])] = [
        (String(localized: "Images"), [
            Tile(symbol: "arrow.2.squarepath", title: String(localized: "Convert"), result: "photo.png"),
            Tile(symbol: "arrow.down.right.and.arrow.up.left", title: String(localized: "Compress"), result: "photo compressed.jpg"),
            Tile(symbol: "scissors", title: String(localized: "Crop"), result: "photo cropped.jpg"),
            Tile(symbol: "pencil.and.outline", title: String(localized: "Annotate"), result: "photo annotated.jpg"),
            Tile(symbol: "rectangle.dashed", title: String(localized: "Redact"), result: "photo redacted.jpg"),
        ]),
        (String(localized: "Recent"), [
            Tile(symbol: "doc.zipper", title: String(localized: "Zip"), result: "photo.zip"),
            Tile(symbol: "arrow.2.squarepath", title: String(localized: "Convert"), result: "photo.png"),
            Tile(symbol: "text.viewfinder", title: "Text", result: "photo.txt"),
            Tile(symbol: "info.circle", title: String(localized: "Info"), result: "photo info"),
            Tile(symbol: "square.and.arrow.up", title: String(localized: "Share"), result: "photo shared"),
        ]),
    ]
    private var tiles: [Tile] { rings[ringIndex].tiles }

    private let size = CGSize(width: 470, height: 250)
    private var center: CGPoint { CGPoint(x: 330, y: 120) }
    private let home = CGPoint(x: 70, y: 120)
    private let radius: CGFloat = 86

    @State private var ringShown = false
    @State private var offset: CGSize = .zero
    @State private var dragging = false
    @State private var done: String?
    @State private var ringIndex = 0
    @State private var switched = false
    @State private var completedDrop = false

    private func position(_ index: Int) -> CGPoint {
        let angle = -Double.pi / 2 + Double(index) * 2 * .pi / Double(tiles.count)
        return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
    }

    private var chip: CGPoint { CGPoint(x: home.x + offset.width, y: home.y + offset.height) }

    private func hovered() -> Int? {
        guard ringShown, dragging else { return nil }
        return tiles.indices.first { hypot(position($0).x - chip.x, position($0).y - chip.y) < 36 }
    }

    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .topLeading) {
                ForEach(tiles.indices, id: \.self) { index in
                    DemoTile(symbol: tiles[index].symbol, title: tiles[index].title, lit: hovered() == index)
                        .position(position(index))
                        .opacity(ringShown ? 1 : 0)
                        .scaleEffect(ringShown ? 1 : 0.4)
                }
                if !ringShown {
                    Text("Press \(triggerTitle) to open the ring")
                        .font(.callout).foregroundStyle(.secondary)
                        .position(center)
                }
                VStack(spacing: 4) {
                    Image(systemName: "photo.fill")
                        .font(.system(size: 24))
                        .frame(width: 54, height: 54)
                        .background(.regularMaterial, in: .rect(cornerRadius: 12, style: .continuous))
                    Text("photo.heic").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .scaleEffect(dragging ? 1.08 : 1)
                .position(chip)
                .gesture(DragGesture(coordinateSpace: .local)
                    .onChanged { value in
                        dragging = true
                        offset = value.translation
                    }
                    .onEnded { _ in
                        if let hit = hovered() { withAnimation(.smooth) { done = tiles[hit].result }; completedDrop = true; completed = switched }
                        dragging = false
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { offset = .zero }
                    })
            }
            .frame(width: size.width, height: size.height)

            Group {
                if let done {
                    Label("Done. Saved next to the original as “\(done)”.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else if ringShown {
                    Text("Drag the file onto an action.").foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 8) {
                        KeyCap(label: triggerTitle == "Shift" ? "⇧" : triggerTitle == "Option" ? "⌥" : "⌃", name: triggerTitle.lowercased(),
                               pressed: keys.isDown(triggerFlag))
                    }
                }
            }
            .font(.callout)
            .frame(height: 44)
            .animation(.smooth(duration: 0.25), value: done)

            if ringShown {
                HStack(spacing: 8) {
                    Text("Ring: \(rings[ringIndex].name)").font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.primary.opacity(0.08), in: .capsule)
                    if switched {
                        Label("Switched. Press \(triggerTitle) again to go back and forth.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text("Press \(triggerTitle) again to switch to the next ring.").foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
            }
        }
        .onChange(of: keys.isDown(triggerFlag)) { _, down in
            guard down else { return }
            if !ringShown {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) { ringShown = true }
            } else {
                // Pressing it again moves to the next ring, like the real thing.
                withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { ringIndex = (ringIndex + 1) % rings.count }
                done = nil
                switched = true
                if done != nil || completedDrop { completed = true }
            }
        }
    }
}

/// Hold ⌥⇧ until the ring fills in.
private struct PopupRingDemo: View {
    @Binding var completed: Bool
    let keys: KeyWatcher
    let delay: Double

    @State private var holdStart: Date?
    @State private var opened = false

    private var held: Bool { keys.isDown(.option) && keys.isDown(.shift) }

    private let tiles = [("wifi", String(localized: "Wi-Fi")), ("dot.radiowaves.left.and.right", String(localized: "Bluetooth")), ("circle.lefthalf.filled", String(localized: "Appearance")),
                         ("square.grid.2x2", String(localized: "Apps")), ("folder", String(localized: "Folders")), ("paperplane.fill", String(localized: "Chats"))]

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                ForEach(tiles.indices, id: \.self) { index in
                    let angle = -Double.pi / 2 + Double(index) * 2 * .pi / Double(tiles.count)
                    DemoTile(symbol: tiles[index].0, title: tiles[index].1)
                        .offset(x: 92 * cos(angle), y: 92 * sin(angle))
                        .opacity(opened ? 1 : 0)
                        .scaleEffect(opened ? 1 : 0.3)
                        .animation(.spring(response: 0.45, dampingFraction: 0.7).delay(Double(index) * 0.03), value: opened)
                }
                if !opened {
                    TimelineView(.animation(paused: holdStart == nil)) { context in
                        let progress = holdStart.map { min(1, context.date.timeIntervalSince($0) / max(delay, 0.1)) } ?? 0
                        Circle().trim(from: 0, to: progress)
                            .stroke(.tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 150, height: 150)
                    }
                }
                HStack(spacing: 10) {
                    KeyCap(label: "⌥", name: "option", pressed: keys.isDown(.option))
                    KeyCap(label: "⇧", name: "shift", pressed: keys.isDown(.shift))
                }
                .scaleEffect(opened ? 0.7 : 1)
                .opacity(opened ? 0.0 : 1)
                .animation(.smooth(duration: 0.3), value: opened)
            }
            .frame(width: 400, height: 250)

            Group {
                if opened {
                    Label("That's it. Point at a tile and let go to use it.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Text("Hold ⌥ and ⇧ together for a moment.").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .frame(height: 24)
        }
        .onChange(of: held) { _, nowHeld in
            guard !opened else { return }
            if nowHeld {
                holdStart = Date()
                let started = holdStart
                Task {
                    try? await Task.sleep(for: .seconds(max(delay, 0.1)))
                    if holdStart == started && held { withAnimation { opened = true }; completed = true }
                }
            } else {
                holdStart = nil
            }
        }
    }
}


// MARK: Permissions

/// What Shiftio may need, with the current state. Nothing here raises a system dialog until its Allow button is pressed.
private struct PermissionsList: View {
    let openSettings: () -> Void

    private enum Status { case allowed, denied, undecided, info(String) }

    @State private var bluetooth = CBManager.authorization
    /// Read up front (it never shows a dialog), so the first thing drawn is the final state and nothing changes afterwards.
    @State private var streamers = Dictionary(uniqueKeysWithValues: Streamer.allCases.map { ($0, $0.access()) })

    private func pane(_ name: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(name)")!)
    }

    private var bluetoothStatus: Status {
        switch bluetooth {
        case .allowedAlways: .allowed
        case .notDetermined: .undecided
        default: .denied
        }
    }

    private func status(of streamer: Streamer) -> Status {
        switch streamers[streamer] ?? .notRunning {
        case .allowed: .allowed
        case .denied: .denied
        case .undecided: .undecided
        case .notRunning: .info(String(localized: "Open \(streamer.name) to allow"))
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            row(String(localized: "Bluetooth"), String(localized: "Turn Bluetooth on and off from the pop-up ring"), "dot.radiowaves.left.and.right", .blue, bluetoothStatus,
                allow: { Bluetooth.requestAccess(); refresh() }, settings: { pane("Privacy_Bluetooth") })
            ForEach(Streamer.allCases) { streamer in
                row(streamer.name, String(localized: "Show and control what's playing"), streamer == .music ? "music.note" : "waveform", .pink, status(of: streamer),
                    allow: {
                        Task.detached {
                            _ = streamer.access(ask: true)
                            let result = streamer.access()
                            await MainActor.run { streamers[streamer] = result }
                        }
                    }, settings: { pane("Privacy_Automation") })
            }
            row(String(localized: "Files & Folders"), String(localized: "Save results next to the original. macOS asks the first time a folder is used."), "folder.fill", .orange,
                .info(String(localized: "Asked when needed")), allow: nil, settings: { pane("Privacy_FilesAndFolders") })

            Button("Open Detailed Settings…", action: openSettings).padding(.top, 4)
        }
        .padding(.horizontal, 24)
        .task { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    /// Reading these never shows a dialog.
    private func refresh() {
        if bluetooth != CBManager.authorization { bluetooth = CBManager.authorization }
        Task.detached {
            var found: [Streamer: Streamer.Access] = [:]
            for streamer in Streamer.allCases { found[streamer] = streamer.access() }
            await MainActor.run { if streamers != found { streamers = found } }
        }
    }

    private func row(_ title: String, _ detail: String, _ symbol: String, _ color: Color, _ status: Status,
                     allow: (() -> Void)?, settings: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(color.gradient, in: .rect(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            statusView(status, allow: allow, settings: settings)
                .animation(nil, value: "\(status)")
        }
        .padding(10)
        .background(.primary.opacity(0.06), in: .rect(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func statusView(_ status: Status, allow: (() -> Void)?, settings: @escaping () -> Void) -> some View {
        Group {
            switch status {
            case .allowed:
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
            case .undecided:
                if let allow { Button("Allow", action: allow).controlSize(.small) }
            case .denied:
                Button("Open Settings", action: settings).controlSize(.small)
            case .info(let text):
                Text(text).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 170, alignment: .trailing)
                Button { settings() } label: { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(.borderless).help("Open System Settings")
            }
        }
        .contentTransition(.identity)
    }
}


/// The apps of the pop-up ring's Apps tile: the usual ones to start with, easy to swap for your own.
private struct OnboardingPinnedApps: View {
    @Bindable private var pins = AppPins.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Pinned apps").font(.system(size: 13, weight: .medium))
                Text("in the pop-up ring").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Add App…", action: choose).controlSize(.small)
                Button("Reset") { pins.ids = AppPins.defaults }.controlSize(.small).disabled(pins.ids == AppPins.defaults)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(pins.ids, id: \.self) { id in
                        let app = AppAction(bundleID: id)
                        VStack(spacing: 3) {
                            Image(nsImage: app.icon ?? NSImage()).resizable().frame(width: 34, height: 34)
                                .overlay(alignment: .topTrailing) {
                                    Button { pins.ids.removeAll { $0 == id } } label: {
                                        Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, .gray)
                                    }
                                    .buttonStyle(.borderless)
                                    .offset(x: 6, y: -6)
                                    .help("Remove \(app.title)")
                                }
                            Text(app.title).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).frame(width: 48)
                        }
                        .padding(.top, 6)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .padding(12)
        .background(.primary.opacity(0.06), in: .rect(cornerRadius: 12, style: .continuous))
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Pin")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { if let id = Bundle(url: url)?.bundleIdentifier { pins.add(id) } }
    }
}
