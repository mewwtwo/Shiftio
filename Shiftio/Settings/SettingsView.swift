import ImageIO
import ServiceManagement
import SwiftUI

enum SettingsTab: String, CaseIterable {
    case general, rings, appearance, about

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .rings: String(localized: "Rings")
        case .appearance: String(localized: "Appearance")
        case .about: String(localized: "About")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .rings: "circle.circle"
        case .appearance: "paintpalette"
        case .about: "info.circle"
        }
    }

    /// Content size of the pane; the window animates between sizes like System Settings used to.
    var size: CGSize {
        switch self {
        case .general: CGSize(width: 520, height: 880)
        case .rings: CGSize(width: 580, height: 700)
        case .appearance: CGSize(width: 520, height: 700)
        case .about: CGSize(width: 520, height: 400)
        }
    }

    /// Smallest the window may be made; the panes are scrolling forms, so they cope with any size above this.
    var minSize: CGSize {
        switch self {
        case .general: CGSize(width: 480, height: 460)
        case .rings: CGSize(width: 520, height: 520)
        case .appearance: CGSize(width: 480, height: 520)
        case .about: CGSize(width: 420, height: 380)
        }
    }

    @MainActor @ViewBuilder
    func content(app: AppState) -> some View {
        switch self {
        case .general: GeneralTab(app: app)
        case .rings: RingsTab(store: app.store)
        case .appearance: AppearanceTab(store: app.store)
        case .about: AboutTab(app: app)
        }
    }
}

/// The tab bar and the open pane. It stays on screen while tabs change, so the highlight slides to the new tab and the old
/// pane gives way to the new one.
struct SettingsRoot: View {
    let app: AppState
    @State private var tab: SettingsTab
    /// Which way the tabs moved, so the new pane enters from that side.
    @State private var forward = true
    let onChange: (SettingsTab) -> Void

    init(app: AppState, tab: SettingsTab, onChange: @escaping (SettingsTab) -> Void) {
        self.app = app
        _tab = State(initialValue: tab)
        self.onChange = onChange
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selection: tab, onSelect: select)
                .padding(.top, 12)
                .padding(.bottom, 10)
            ZStack {
                tab.content(app: app)
                    .id(tab)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: forward ? 28 : -28)),
                                            removal: .opacity.combined(with: .offset(x: forward ? -28 : 28))))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        // The title bar is transparent and sits over the content; the tab bar starts just under the traffic lights.
        .padding(.top, 30)
        .ignoresSafeArea(.container, edges: .top)
        // The accent setting is for the rings; windows follow the system accent colour.
        .tint(Color(nsColor: .controlAccentColor))
    }

    /// Reads what the panes need from disk (the desktop picture for the preview) before they are opened.
    static func warmUp() { PreviewBackground.warmUp() }

    private func select(_ picked: SettingsTab) {
        guard picked != tab else { return }
        forward = (SettingsTab.allCases.firstIndex(of: picked) ?? 0) > (SettingsTab.allCases.firstIndex(of: tab) ?? 0)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { tab = picked }
        onChange(picked)
    }
}

/// One row of equal icon tabs with a single highlight, in the same style as the file-type picker.
private struct SettingsTabBar: View {
    let selection: SettingsTab
    let onSelect: (SettingsTab) -> Void
    @Namespace private var space

    var body: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                let isSelected = tab == selection
                Button { onSelect(tab) } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 18))
                            .symbolVariant(isSelected ? .fill : .none)
                        Text(tab.title).font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .frame(width: 84, height: 50)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.tint)
                                .matchedGeometryEffect(id: "tab", in: space)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(.primary.opacity(0.06), in: .rect(cornerRadius: 14, style: .continuous))
        .frame(maxWidth: .infinity)
    }
}

/// A settings label in the style of System Settings: a white symbol on a coloured rounded square.
struct SettingLabel: View {
    let title: LocalizedStringKey
    let symbol: String
    var color: Color = .blue

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(color.gradient, in: .rect(cornerRadius: 6, style: .continuous))
        }
    }
}

struct GeneralTab: View {
    @Bindable var app: AppState
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage(ScreenCapture.quickLookKey) private var captureQuickLook = true
    @State private var language = AppLanguage.chosen

    private func askToRestart() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Restart Shiftio to change the language?")
        alert.informativeText = String(localized: "The new language is used the next time Shiftio starts.")
        alert.addButton(withTitle: String(localized: "Restart Now"))
        alert.addButton(withTitle: String(localized: "Later"))
        if alert.runModal() == .alertFirstButtonReturn { AppLanguage.relaunch() }
    }

    var body: some View {
        @Bindable var store = app.store
        Form {
            // Whether the app runs at all.
            Section {
                Toggle(isOn: $app.isEnabled) { SettingLabel(title: "Enable Shiftio", symbol: "power", color: .green) }
                Toggle(isOn: $launchAtLogin) { SettingLabel(title: "Open at login", symbol: "sunrise.fill", color: .orange) }
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            enabled ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister()
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            } header: {
                Text("Shiftio")
            }

            Section {
                Picker(selection: $language) {
                    ForEach(AppLanguage.allCases) { Text($0.nativeName).tag($0) }
                } label: { SettingLabel(title: "Language", symbol: "globe", color: .blue) }
                    .onChange(of: language) { _, picked in
                        AppLanguage.chosen = picked
                        askToRestart()
                    }
            } footer: {
                Text("Takes effect after Shiftio restarts. If macOS uses a language Shiftio doesn't have yet, English is shown.")
            }

            // The ring that opens while a file is being dragged.
            Section {
                Picker(selection: $store.config.trigger) {
                    ForEach(TriggerModifier.allCases) { Text($0.title).tag($0) }
                } label: { SettingLabel(title: "Trigger key", symbol: "keyboard", color: .indigo) }
                    .onChange(of: store.config.trigger) { app.applyEnabled() }
                Toggle(isOn: $store.config.hideOnModifierRelease) {
                    SettingLabel(title: "Hide when the key is released", symbol: "eye.slash.fill", color: .gray)
                }
                Toggle(isOn: $store.config.revealInFinder) {
                    SettingLabel(title: "Reveal results in Finder", symbol: "folder.fill", color: .blue)
                }
                Toggle(isOn: $store.config.recentRingEnabled) {
                    SettingLabel(title: "Recent tools ring first", symbol: "clock.arrow.circlepath", color: .purple)
                }
            } header: {
                Text("File ring")
            } footer: {
                Text("Drag a file and press the trigger key. Press it again to switch rings. The Recent ring holds the tools you used last and most often on that kind of file. Results are saved next to the original.")
            }

            // The ring of system controls opened by holding keys.
            Section {
                Toggle(isOn: $store.config.controlRingEnabled) {
                    SettingLabel(title: "Pop-up rings", symbol: "circle.hexagongrid.fill", color: .purple)
                }
                .onChange(of: store.config.controlRingEnabled) { app.applyEnabled() }
                if store.config.controlRingEnabled {
                    LabeledContent {
                        HStack(spacing: 8) {
                            ResettableSlider(value: $store.config.controlRingDelay, range: 0.15...0.8, defaultValue: 0.3)
                                .frame(width: 140)
                                .onChange(of: store.config.controlRingDelay) { app.applyEnabled() }
                            Text(String(format: "%.2f s", store.config.controlRingDelay))
                                .monospacedDigit().foregroundStyle(.secondary).frame(width: 50, alignment: .trailing)
                        }
                    } label: { SettingLabel(title: "Hold for", symbol: "timer", color: .pink) }
                }
                Toggle(isOn: $captureQuickLook) {
                    SettingLabel(title: "Open captures in Quick Look", symbol: "eye.fill", color: .teal)
                }
            } header: {
                Text("Pop-up rings")
            } footer: {
                Text("Hold the combination set for a ring (⌥⇧ by default). Point at an item and let go, or click. Set the keys in Rings → Pop-up. Screenshot and Record Video are in the list of tiles there; with Quick Look on, a finished capture opens as a preview.")
            }

            Section {
                Toggle(isOn: $store.config.nowPlayingEnabled) {
                    SettingLabel(title: "Player above the System ring", symbol: "music.note", color: .red)
                }
                if store.config.nowPlayingEnabled {
                    ForEach(Streamer.allCases) { streamer in StreamerAccessRow(streamer: streamer) }
                }
            } header: {
                Text("Music player")
            } footer: {
                Text("Cover, track buttons and a seek bar. Click the cover to open the app, or the player for lyrics and the queue. Shiftio only asks to control an app when you press Allow.")
            }

            Section {
                Picker(selection: $store.config.audioFormat) {
                    ForEach(AudioFormat.allCases) { Text($0.title).tag($0) }
                } label: { SettingLabel(title: "Convert audio to", symbol: "waveform", color: .teal) }
                if store.config.audioFormat == .mp3 {
                    Picker(selection: $store.config.mp3Bitrate) {
                        ForEach([128, 192, 256, 320], id: \.self) { Text("\($0) kbps").tag($0) }
                    } label: { SettingLabel(title: "MP3 quality", symbol: "slider.horizontal.3", color: .teal) }
                    if app.components.mp3 != .installed {
                        Label("The MP3 encoder isn't installed yet. See Downloads below.", systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("Audio")
            } footer: {
                Text("The Audio sector in the ring uses this format. Each format is also its own sector in Rings.")
            }

            Section {
                LabeledContent {
                    MP3Status(components: app.components)
                } label: { SettingLabel(title: "MP3 encoder", symbol: "arrow.down.circle.fill", color: .cyan) }
                LabeledContent {
                    SpeechAssetsStatus(assets: app.speech)
                } label: { SettingLabel(title: "Speech recognition", symbol: "mic.fill", color: .mint) }
            } header: {
                Text("Downloads")
            } footer: {
                Text("Shiftio fetches these itself the first time it opens. The speech model is Apple's on-device model for your language.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct MP3Status: View {
    let components: ComponentInstaller

    var body: some View {
        HStack(spacing: 8) {
            switch components.mp3 {
            case .checking:
                ProgressView().controlSize(.small)
            case .installed:
                Label(MP3Encoder.locate()?.isManaged == false ? "Using system copy" : "Installed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
            case .missing:
                Button("Download") { Task { await components.installMP3() } }
            case .installing(let text):
                ProgressView().controlSize(.small)
                Text(text).foregroundStyle(.secondary).lineLimit(1)
            case .failed(let message):
                Text(message).foregroundStyle(.red).lineLimit(1)
                Button("Retry") { Task { await components.installMP3() } }
            }
        }
        .task { components.refresh() }
    }
}

private struct SpeechAssetsStatus: View {
    let assets: SpeechAssets

    var body: some View {
        HStack(spacing: 8) {
            switch assets.status {
            case .checking:
                ProgressView().controlSize(.small)
            case .installed:
                Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
            case .downloading:
                ProgressView().controlSize(.small)
                Text("Downloading…").foregroundStyle(.secondary)
            case .missing:
                Button("Download") { Task { await assets.install() } }
            case .unsupported:
                Text("Not available for this language").foregroundStyle(.secondary)
            case .failed(let message):
                Text(message).foregroundStyle(.red).lineLimit(1)
                Button("Retry") { Task { await assets.install() } }
            }
        }
        .task { await assets.refresh() }
    }
}

struct RingsTab: View {
    @Bindable var store: ConfigStore
    @State private var category: FileCategory

    init(store: ConfigStore) {
        self.store = store
        // `-ShiftioRingsCategory system` opens on that file type (for screenshots).
        let name = UserDefaults.standard.string(forKey: "ShiftioRingsCategory") ?? ""
        _category = State(initialValue: FileCategory(rawValue: name) ?? .pdf)
    }

    private var compatible: [any FileAction] {
        ActionRegistry.all.filter { action in
            if category == .system { return action is ControlAction }
            if action is ShortcutAction || action is AppAction { return false }   // added through "Add Action" instead
            // Batch rings may hold any action; it's applied to every dragged file.
            return category == .batch || (action.minimumFileCount == 1 && action.accepts(category.sampleType))
        }
    }

    private var rings: Binding<[RingConfig]> {
        Binding(get: { store.config.rings[category] ?? [] }, set: { store.config.rings[category] = $0 })
    }

    private func takenTriggers(except id: UUID?) -> Set<ChordTrigger> {
        Set((store.config.rings[.system] ?? []).filter { $0.id != id }.compactMap(\.trigger))
    }

    /// A key combination belongs to one ring; assigning it here takes it away from any other.
    private func claim(_ trigger: ChordTrigger, for id: UUID) {
        store.config.rings[.system] = (store.config.rings[.system] ?? []).map { ring in
            var ring = ring
            if ring.id != id, ring.trigger == trigger { ring.trigger = nil }
            return ring
        }
    }

    var body: some View {
        Form {
            Section {
                CategoryPicker(selection: $category)
                    .listRowInsets(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10))
                    .listRowBackground(Color.clear)
            } footer: {
                Text(category == .system
                     ? "Pop-up rings open when you hold their key combination. Add system controls, Shortcuts, favourite apps, or the apps you used recently or most. The paintbrush changes an item's name and icon."
                     : "Each ring is a set of actions. Items sit on the ring in this order: 1 is at the top, the rest follow clockwise. Drag to reorder; pressing the trigger key again switches rings. The paintbrush changes an item's name and icon.")
            }

            ForEach(rings) { $ring in
                RingEditor(ring: $ring, category: category, actions: compatible, store: store,
                           claimTrigger: { trigger in claim(trigger, for: ring.id) },
                           takenTriggers: takenTriggers(except: ring.id)) {
                    withAnimation(.smooth) { store.config.rings[category]?.removeAll { $0.id == ring.id } }
                }
            }

            if category == .system {
                PinnedFoldersSection(store: store)
                PinnedAppsSection()
                TelegramChatsSection()
                SuggestedAppsSection()
            }

            UsageHistorySection()

            Section {
                Button("Add Ring") {
                    withAnimation(.smooth) {
                        let free = ChordTrigger.allCases.first { !takenTriggers(except: nil).contains($0) }
                        store.config.rings[category, default: []].append(
                            RingConfig(name: "New Ring", center: nil, trigger: category == .system ? free : nil, segments: []))
                    }
                }
                Button("Reset All Rings to Defaults", role: .destructive) { withAnimation(.smooth) { store.resetRings() } }
            }
        }
        .formStyle(.grouped)
    }
}

private extension FileCategory {
    var symbol: String {
        switch self {
        case .batch: "square.on.square"
        case .pdf: "doc.richtext"
        case .image: "photo"
        case .document: "doc.text"
        case .media: "waveform"
        case .system: "switch.2"
        }
    }

    var shortTitle: String {
        switch self {
        case .batch: String(localized: "Multiple")
        case .pdf: "PDF"
        case .image: String(localized: "Images")
        case .document: String(localized: "Docs")
        case .media: String(localized: "Media")
        case .system: String(localized: "System")
        }
    }
}

/// File types as a row of icon cards; the highlight slides between them.
private struct CategoryPicker: View {
    @Binding var selection: FileCategory
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 6) {
            ForEach(FileCategory.allCases) { category in
                let isSelected = category == selection
                Button {
                    withAnimation(.smooth(duration: 0.25)) { selection = category }
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: category.symbol)
                            .font(.system(size: 18, weight: .regular))
                            .symbolVariant(isSelected ? .fill : .none)
                        Text(category.shortTitle).font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(.tint)
                                .matchedGeometryEffect(id: "selection", in: namespace)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(category.title)
            }
        }
        .padding(4)
        .background(.primary.opacity(0.06), in: .rect(cornerRadius: 13, style: .continuous))
    }
}

struct AppearanceTab: View {
    @Bindable var store: ConfigStore
    @State private var preview = RadialState()

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                RingPreview(state: preview, diameter: store.config.appearance.diameter)
                    .listRowInsets(EdgeInsets())
            }

            // Colour of the highlights on the ring, the Touch Bar and the music player.
            Section {
                Toggle(isOn: $store.config.appearance.accentEnabled.animation(.smooth(duration: 0.25))) {
                    SettingLabel(title: "Coloured highlights", symbol: "paintpalette.fill", color: .orange)
                }
                if store.config.appearance.accentEnabled {
                    Toggle(isOn: $store.config.appearance.useSystemAccent) {
                        SettingLabel(title: "Use the system accent colour", symbol: "apple.logo", color: .gray)
                    }
                    ColorPicker(selection: Binding(
                        get: { store.config.appearance.tint.color },
                        set: { store.config.appearance.tint = RGBAColor($0) })) {
                        SettingLabel(title: "Custom colour", symbol: "eyedropper", color: .pink)
                    }
                    .disabled(store.config.appearance.useSystemAccent)
                    LabeledContent {
                        HStack(spacing: 8) {
                            Text("Soft").font(.caption).foregroundStyle(.secondary)
                            ResettableSlider(value: $store.config.appearance.accentIntensity, range: 0.2...1, defaultValue: 0.6)
                                .frame(width: 140)
                            Text("Vivid").font(.caption).foregroundStyle(.secondary)
                        }
                    } label: { SettingLabel(title: "Intensity", symbol: "circle.lefthalf.filled", color: .purple) }
                }
            } header: {
                Text("Colour")
            } footer: {
                Text(store.config.appearance.accentEnabled
                     ? "Used by the rings, the Touch Bar and the music player. Settings and editor windows always follow the system accent colour."
                     : "Highlights on the rings and the player are gray. Settings and editor windows keep the system accent colour.")
            }

            // What the rings, the player and the editor windows are made of.
            Section {
                Picker(selection: Binding(get: { store.config.appearance.theme },
                                          set: { store.config.appearance.theme = $0; $0.apply() })) {
                    ForEach(AppTheme.allCases) { Text($0.title).tag($0) }
                } label: { SettingLabel(title: "Theme", symbol: "circle.lefthalf.filled.righthalf.striped.horizontal", color: .indigo) }
                Picker(selection: $store.config.appearance.glassStyle.animation(.smooth(duration: 0.25))) {
                    ForEach(GlassStyle.allCases) { Text($0.title).tag($0) }
                } label: { SettingLabel(title: "Material", symbol: "square.stack.3d.up.fill", color: .teal) }
                if store.config.appearance.glassStyle != .solid {
                    LabeledContent {
                        HStack(spacing: 8) {
                            Text("Clear").font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                            ResettableSlider(value: $store.config.appearance.glassTint, range: 0...0.5, defaultValue: 0.1)
                                .frame(width: 100)
                            Text("Tinted").font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                        }
                    } label: { SettingLabel(title: "Tint", symbol: "drop.fill", color: .blue) }
                }
                if store.config.appearance.glassStyle == .frosted {
                    LabeledContent {
                        HStack(spacing: 8) {
                            Text(String(localized: "frost.light", defaultValue: "Light")).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                            ResettableSlider(value: $store.config.appearance.glassFrost, range: 0...1, defaultValue: 0.5)
                                .frame(width: 100)
                            Text("Heavy").font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                        }
                    } label: { SettingLabel(title: "Blur", symbol: "aqi.medium", color: .cyan) }
                }
            } header: {
                Text("Glass")
            } footer: {
                Text("Follow macOS uses the Liquid Glass look from System Settings. With Reduce Transparency on, macOS always makes glass solid.")
            }

            Section {
                LabeledContent {
                    ResettableSlider(value: $store.config.appearance.diameter, range: 260...460, defaultValue: 340, step: 10)
                        .frame(width: 180)
                } label: { SettingLabel(title: "Size", symbol: "arrow.up.left.and.arrow.down.right", color: .indigo) }
                Toggle(isOn: $store.config.appearance.showIcons) {
                    SettingLabel(title: "Show icons", symbol: "photo.fill", color: .green)
                }
                Toggle(isOn: $store.config.appearance.showLabels) {
                    SettingLabel(title: "Show labels", symbol: "textformat", color: .gray)
                }
            } header: {
                Text("Ring")
            } footer: {
                Text("Double-click a slider to put it back to its default.")
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        // Dragging a slider only changes how the preview looks: the ring in it is not rebuilt, which restarted its glass
        // (and made it flicker) on every tick.
        .onChange(of: store.config.appearance) { preview.appearance = store.config.appearance }
    }

    private func refresh() {
        preview.appearance = store.config.appearance
        preview.rings = (store.config.rings[.image] ?? []).compactMap { ResolvedRing($0) { $0.accepts(.png) } }
        preview.ringIndex = 0
        preview.hover = .segment(1)
        preview.isVisible = true
    }
}

/// Backdrops to look at the glass against: colourful, dark, light, a busy pattern and the real desktop picture.
private enum PreviewBackground: String, CaseIterable, Identifiable {
    case sunset, ocean, aurora, forest, graphite, light, pattern, desktop
    var id: String { rawValue }

    var title: String {
        switch self {
        case .sunset: String(localized: "Sunset")
        case .ocean: String(localized: "Ocean")
        case .aurora: String(localized: "Aurora")
        case .forest: String(localized: "Forest")
        case .graphite: String(localized: "Graphite")
        case .light: String(localized: "Light")
        case .pattern: String(localized: "Pattern")
        case .desktop: String(localized: "Desktop")
        }
    }

    @ViewBuilder
    var view: some View {
        switch self {
        case .sunset:
            LinearGradient(colors: [.orange, .pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing).opacity(0.9)
        case .ocean:
            LinearGradient(colors: [Color(red: 0.0, green: 0.75, blue: 0.85), Color(red: 0.05, green: 0.3, blue: 0.75),
                                    Color(red: 0.1, green: 0.1, blue: 0.4)], startPoint: .top, endPoint: .bottom)
        case .aurora:
            ZStack {
                Color(red: 0.03, green: 0.05, blue: 0.14)
                RadialGradient(colors: [Color(red: 0.1, green: 0.95, blue: 0.6).opacity(0.85), .clear],
                               center: UnitPoint(x: 0.25, y: 0.35), startRadius: 0, endRadius: 190)
                RadialGradient(colors: [Color(red: 0.6, green: 0.3, blue: 1).opacity(0.85), .clear],
                               center: UnitPoint(x: 0.8, y: 0.6), startRadius: 0, endRadius: 200)
            }
        case .forest:
            LinearGradient(colors: [Color(red: 0.55, green: 0.8, blue: 0.3), Color(red: 0.05, green: 0.4, blue: 0.25),
                                    Color(red: 0.02, green: 0.15, blue: 0.12)], startPoint: .topTrailing, endPoint: .bottomLeading)
        case .graphite:
            LinearGradient(colors: [Color(white: 0.28), Color(white: 0.08)], startPoint: .top, endPoint: .bottom)
        case .light:
            LinearGradient(colors: [Color(white: 0.98), Color(white: 0.78)], startPoint: .top, endPoint: .bottom)
        case .pattern:
            // Fine stripes and blocks: shows how much the glass blurs and bends what is behind it.
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.12)))
                var x: CGFloat = 0
                var flip = false
                while x < size.width {
                    context.fill(Path(CGRect(x: x, y: 0, width: 6, height: size.height)), with: .color(flip ? .white.opacity(0.85) : .cyan.opacity(0.7)))
                    x += 12
                    flip.toggle()
                }
                var y: CGFloat = 8
                while y < size.height {
                    context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 3)), with: .color(.pink.opacity(0.8)))
                    y += 24
                }
            }
        case .desktop:
            if let image = Self.wallpaper {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Color.gray
            }
        }
    }

    static func warmUp() { Task.detached(priority: .utility) { _ = wallpaper } }

    /// The desktop picture, read once and shrunk. It was read from disk in full every time the pane drew, which is what made
    /// switching to Appearance slow.
    private static let wallpaper: NSImage? = {
        guard let screen = NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 900]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))
    }()
}

/// The real ring scaled to fit a fixed stage. The stage is a plain clear box with an overlay,
/// so the ring's own (larger) layout size can't stretch the form row.
private struct RingPreview: View {
    let state: RadialState
    let diameter: Double

    private let stageHeight: CGFloat = 250
    @AppStorage("appearancePreviewBackground") private var backgroundName = PreviewBackground.sunset.rawValue

    private var background: PreviewBackground { PreviewBackground(rawValue: backgroundName) ?? .sunset }

    /// Round samples of each backdrop; the ring is judged against whichever one is picked.
    private var swatches: some View {
        HStack(spacing: 8) {
            ForEach(PreviewBackground.allCases) { option in
                Button { backgroundName = option.rawValue } label: {
                    option.view
                        .frame(width: 22, height: 22)
                        .clipShape(.circle)
                        .overlay { Circle().stroke(.white.opacity(option == background ? 0.95 : 0.35), lineWidth: option == background ? 2 : 1) }
                        .scaleEffect(option == background ? 1.12 : 1)
                }
                .buttonStyle(.plain)
                .help(option.title)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.primary.opacity(0.08), in: .capsule)
    }

    var body: some View {
        let natural = RadialGeometry(diameter: diameter, segmentCount: 1, hasCenter: false).panelSize
        let scale = min(1, (stageHeight - 8) / natural.height)

        VStack(spacing: 0) {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: stageHeight)
            .overlay {
                ZStack {
                    background.view.id(background)
                        .transition(.opacity)
                    RadialMenuView(state: state)
                        .frame(width: natural.width, height: natural.height)
                        .scaleEffect(scale)
                        .animation(.smooth(duration: 0.3), value: diameter)
                }
            }
            .clipShape(.rect(cornerRadius: 10, style: .continuous))
            .animation(.smooth(duration: 0.3), value: background)
            // Under the stage, not over it, so the samples never cover the ring.
            swatches.padding(.vertical, 10)
        }
    }
}

struct AboutTab: View {
    let app: AppState

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
            Text("Shiftio").font(.title.weight(.semibold)).padding(.top, 4)
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                .foregroundStyle(.secondary)
            Text("Drag a file, press ⇧, drop it on an action.")
                .padding(.top, 8)
            Text("Hold ⌥⇧ for the pop-up ring of system controls.")
            Button("Show Tutorial") { app.showOnboarding() }
                .padding(.top, 8)
            Spacer().frame(height: 14)
            Text("Dev team").font(.caption).foregroundStyle(.tertiary)
            Text("Dmytro Demchuk").font(.callout.weight(.medium))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Folders offered by the Folders tile: drag to reorder, add any folder, remove the ones you don't want.
private struct PinnedFoldersSection: View {
    @Bindable private var pins = FolderPins.shared
    @Bindable var store: ConfigStore
    @State private var editingID: String?

    var body: some View {
        Section {
            ForEach(pins.items) { folder in
                HStack(spacing: 10) {
                    Group {
                        if let icon = pins.icon(for: folder, style: store.config.itemStyles["folder-" + folder.id]) {
                            Image(nsImage: icon).resizable()
                        } else {
                            Image(systemName: "clock").foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(folder.title)
                        if !folder.isRecents {
                            Text(folder.id.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Spacer()
                    Button { editingID = folder.id } label: { Image(systemName: "paintbrush.pointed") }
                        .buttonStyle(.borderless)
                        .help("Change name and icon")
                    Button {
                        withAnimation(.smooth(duration: 0.2)) { pins.items.removeAll { $0.id == folder.id } }
                    } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.borderless)
                        .help("Remove from Folders")
                }
                .reorderable(id: folder.id, number: (pins.items.firstIndex { $0.id == folder.id } ?? 0) + 1) { dragged, target in pins.items.move(dragged, onto: target) { $0.id } }
            }
            .sheet(item: Binding(get: { editingID.map(EditTarget.init) }, set: { editingID = $0?.id })) { target in
                IconEditor(id: "folder-" + target.id, store: store,
                           defaultTitle: pins.items.first { $0.id == target.id }?.title ?? String(localized: "Folder")) { editingID = nil }
            }

            if pins.items.count > 1 { RingOrderHint(count: pins.items.count) }

            HStack {
                Button("Add Folder…") { chooseFolders() }
                if !pins.items.contains(where: \.isRecents) {
                    Button("Add Recents") { pins.items.append(PinnedFolder(id: PinnedFolder.recentsID, title: String(localized: "Recents"))) }
                }
                Spacer()
                Button("Reset", role: .destructive) { withAnimation(.smooth) { pins.resetToDefaults() } }
            }
        } header: {
            Text("Pinned Folders")
        } footer: {
            Text("Shown by the Folders tile, in this order: 1 is at the top of the ring, the rest follow clockwise. Drag to reorder. Choosing one opens it in Finder.")
        }
    }

    private struct EditTarget: Identifiable { let id: String }

    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Pin")
        guard panel.runModal() == .OK else { return }
        withAnimation(.smooth) { panel.urls.forEach(pins.add) }
    }
}

/// Apps offered by the Apps tile: drag to reorder, add any app, remove the ones you don't want.
private struct PinnedAppsSection: View {
    @Bindable private var pins = AppPins.shared

    var body: some View {
        Section {
            ForEach(pins.ids, id: \.self) { id in
                let app = AppAction(bundleID: id)
                HStack(spacing: 10) {
                    Image(nsImage: app.icon ?? NSImage()).resizable().frame(width: 22, height: 22)
                    Text(app.title)
                    Spacer()
                    Button {
                        withAnimation(.smooth(duration: 0.2)) { pins.ids.removeAll { $0 == id } }
                    } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.borderless)
                        .help("Remove from Apps")
                }
                .reorderable(id: id, number: (pins.ids.firstIndex(of: id) ?? 0) + 1) { dragged, target in pins.ids.move(dragged, onto: target) { $0 } }
            }

            if pins.ids.count > 1 { RingOrderHint(count: pins.ids.count) }

            Button("Add App…") { chooseApps() }
        } header: {
            Text("Pinned Apps")
        } footer: {
            Text("Shown by the Apps tile, in this order: 1 is at the top of the ring, the rest follow clockwise. Drag to reorder. Choosing one opens it.")
        }
    }

    private func chooseApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Pin")
        guard panel.runModal() == .OK else { return }
        withAnimation(.smooth) {
            for url in panel.urls { if let id = Bundle(url: url)?.bundleIdentifier { pins.add(id) } }
        }
    }
}

/// One pinned chat: a picture that is also a drop target, with buttons to choose or reset it.
private struct TelegramChatRow: View {
    let chat: TelegramChat
    let chats: TelegramChats
    let choosePicture: () -> Void
    @State private var dropping = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: chats.image(for: chat) ?? NSImage())
                .resizable()
                .frame(width: 28, height: 28)
                .padding(3)
                .overlay(Circle().strokeBorder(dropping ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary.opacity(0.5)),
                                               style: StrokeStyle(lineWidth: dropping ? 2 : 1, dash: [3, 3])))
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first else { return false }
                    chats.setCustomAvatar(url, for: chat)
                    return true
                } isTargeted: { dropping = $0 }
                .animation(.smooth(duration: 0.15), value: dropping)
                .help("Drop an image here")
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.title)
                Text("Drop an image on the picture or").font(.caption).foregroundStyle(.secondary)
            }
            Button("Choose Picture…", action: choosePicture).controlSize(.small)
            Button("Reset") { chats.setCustomAvatar(nil, for: chat) }
                .controlSize(.small)
                .disabled(!chats.hasCustomAvatar(chat))
                .help("Go back to the picture from Telegram")
            Spacer(minLength: 0)
            Button {
                withAnimation(.smooth(duration: 0.2)) { chats.remove(chat) }
            } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.borderless)
                .help("Remove chat")
        }
    }
}

/// Telegram chats shown by the Apps tile, after the apps.
private struct TelegramChatsSection: View {
    @Bindable private var chats = TelegramChats.shared
    @State private var name = ""
    @State private var link = ""

    private var canAdd: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && TelegramChat.link(from: link) != nil }

    var body: some View {
        Section {
            ForEach(chats.items) { chat in
                TelegramChatRow(chat: chat, chats: chats, choosePicture: { choosePicture(for: chat) })
            }
            TextField("Name", text: $name, prompt: Text("Mom"))
            TextField("Link", text: $link, prompt: Text("@username, t.me/username or +380…"))
            Button("Add Chat") {
                if chats.add(title: name, input: link) { name = ""; link = "" }
            }
            .disabled(!canAdd)
        } header: {
            Text("Telegram Chats")
        } footer: {
            Text("Shown by the Apps tile after the apps. Choosing one opens that conversation in Telegram. A person without a public username can be added by phone number (+380…) or user id. Give a chat your own picture with Choose Picture… or by dropping an image on it; Reset goes back to Telegram's.")
        }
    }

    private func choosePicture(for chat: TelegramChat) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.prompt = String(localized: "Use Picture")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        chats.setCustomAvatar(url, for: chat)
    }
}

/// Clears what the Recent and Frequent tiles remember.
private struct UsageHistorySection: View {
    var body: some View {
        Section {
            Button("Clear Recent Apps") { AppUsage.shared.clear() }
            Button("Clear Recent Tools") { ToolUsage.shared.clear() }
        } header: {
            Text("History")
        } footer: {
            Text("Empties the lists behind the Recent and Frequent tiles. Files are untouched.")
        }
    }
}

/// What the merged Recent tile lists.
private struct SuggestedAppsSection: View {
    @AppStorage(SuggestedAppsMode.modeKey) private var mode = SuggestedAppsMode.mixed.rawValue
    @AppStorage(SuggestedAppsMode.countKey) private var count = 6

    var body: some View {
        Section {
            Picker("Show", selection: $mode) {
                ForEach(SuggestedAppsMode.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Stepper("Number of apps: \(count)", value: $count, in: 2...10)
        } header: {
            Text("Recent Apps")
        } footer: {
            Text("The Recent tile lists apps you used lately, the ones you use most, or both.")
        }
    }
}

/// Whether Shiftio may control a streaming app, with a button that asks (the system's own question appears only then).
private struct StreamerAccessRow: View {
    let streamer: Streamer
    @State private var access = Streamer.Access.notRunning

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                switch access {
                case .allowed: Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .denied: Text("Not allowed. Turn it on in System Settings → Privacy & Security → Automation.").foregroundStyle(.secondary)
                case .undecided:
                    Button("Allow") {
                        Task.detached {
                            _ = streamer.access(ask: true)
                            let result = streamer.access()
                            await MainActor.run { access = result }
                        }
                    }
                case .notRunning: Text("Open the app to allow it").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        } label: {
            SettingLabel(title: LocalizedStringKey(streamer.name), symbol: streamer == .music ? "applelogo" : "dot.radiowaves.left.and.right",
                         color: streamer == .music ? .pink : .green)
        }
        .task { access = streamer.access() }
    }
}
