import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One ring in Settings: its name, trigger (pop-up rings), and a reorderable list of items, each of which
/// can be given a name and icon of its own.
struct RingEditor: View {
    @Binding var ring: RingConfig
    let category: FileCategory
    let actions: [any FileAction]
    @Bindable var store: ConfigStore
    let claimTrigger: (ChordTrigger) -> Void
    let takenTriggers: Set<ChordTrigger>
    let onDelete: () -> Void

    @State private var showShortcuts = false

    var body: some View {
        Section {
            TextField("Name", text: Binding(get: { RingConfig.displayName(ring.name) }, set: { ring.name = $0 }))

            if category == .system {
                Picker("Hold to open", selection: $ring.trigger) {
                    Text("Not assigned").tag(ChordTrigger?.none)
                    ForEach(ChordTrigger.allCases) { trigger in
                        Text(trigger.title + (takenTriggers.contains(trigger) ? String(localized: "  (moves here)") : "")).tag(Optional(trigger))
                    }
                }
                .onChange(of: ring.trigger) { _, new in if let new { claimTrigger(new) } }
            } else {
                Picker("Center", selection: $ring.center) {
                    Text("Empty (drop to cancel)").tag(String?.none)
                    ForEach(actions, id: \.id) { Text($0.title).tag(Optional($0.id)) }
                }
            }

            ForEach(ring.segments, id: \.self) { id in
                RingItemRow(id: id, store: store) {
                    withAnimation(.smooth(duration: 0.2)) { ring.segments.removeAll { $0 == id } }
                }
                .reorderable(id: id, number: (ring.segments.firstIndex(of: id) ?? 0) + 1) { dragged, target in ring.segments.move(dragged, onto: target) { $0 } }
            }

            if ring.segments.count > 1 { RingOrderHint(count: ring.segments.count) }

            HStack {
                addMenu
                Spacer()
                Button("Delete Ring", role: .destructive, action: onDelete)
            }
        } header: {
            Text(ring.name.isEmpty ? String(localized: "Ring") : RingConfig.displayName(ring.name))
        }
        .sheet(isPresented: $showShortcuts) {
            ShortcutPicker { name in add("shortcut:" + name) }
        }
    }

    private func add(_ id: String) {
        guard !ring.segments.contains(id) else { return }
        withAnimation(.smooth(duration: 0.2)) { ring.segments.append(id) }
    }

    private var addMenu: some View {
        Menu("Add Action") {
            ForEach(actions.filter { !ring.segments.contains($0.id) }, id: \.id) { action in
                Button(action.title) { add(action.id) }
            }
            Divider()
            Button("Shortcut…") { showShortcuts = true }
            if category == .system {
                Button("App…") { chooseApp() }
            }
        }
        .fixedSize()
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let bundleID = Bundle(url: url)?.bundleIdentifier { add("app:" + bundleID) }
        }
    }
}

// MARK: Item row and icon

private struct ItemIconView: View {
    let look: ItemPresentation
    var size: CGFloat = 22

    var body: some View {
        Group {
            if let image = look.image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else if let emoji = look.emoji {
                Text(emoji).font(.system(size: size * 0.8))
            } else {
                Image(systemName: look.symbol ?? "circle.dashed").font(.system(size: size * 0.7)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

struct RingItemRow: View {
    let id: String
    @Bindable var store: ConfigStore
    let onRemove: () -> Void
    @State private var editing = false

    private var look: ItemPresentation {
        if let action = ActionRegistry.action(id) {
            return ItemCatalog.presentation(of: action, style: store.config.itemStyles[id])
        }
        let isRecent = id.contains("recent")
        return ItemPresentation(title: ItemCatalog.rowTitle(id, styles: store.config.itemStyles),
                                symbol: isRecent ? "clock.arrow.circlepath" : "chart.bar", emoji: nil, image: nil)
    }

    var body: some View {
        HStack(spacing: 10) {
            ItemIconView(look: look)
            VStack(alignment: .leading, spacing: 0) {
                Text(ItemCatalog.dynamic(id) == nil ? look.title : ItemCatalog.rowTitle(id, styles: store.config.itemStyles))
                if id.hasPrefix("shortcut:") {
                    Text("Shortcut").font(.caption).foregroundStyle(.secondary)
                } else if ItemCatalog.dynamic(id) != nil {
                    Text("Filled in automatically").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if ItemCatalog.dynamic(id) == nil {
                Button { editing = true } label: { Image(systemName: "paintbrush.pointed") }
                    .buttonStyle(.borderless)
                    .help("Change name and icon")
                    .sheet(isPresented: $editing) {
                        IconEditor(id: id, store: store, defaultTitle: ActionRegistry.action(id)?.title ?? id) { editing = false }
                    }
            }
            Button(action: onRemove) { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.borderless)
                .help("Remove from ring")
        }
    }
}

/// Pick a name and an icon for one item: an SF Symbol by name (as written in the SF Symbols app),
/// an emoji, or any picture.
struct IconEditor: View {
    enum Mode: String, CaseIterable, Identifiable {
        case automatic = "Default", symbol = "SF Symbol", emoji = "Emoji", picture = "Picture"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .automatic: String(localized: "Default")
            case .symbol: String(localized: "SF Symbol")
            case .emoji: String(localized: "Emoji")
            case .picture: String(localized: "Picture")
            }
        }
    }

    let id: String
    @Bindable var store: ConfigStore
    let defaultTitle: String
    let onDone: () -> Void

    @State private var mode = Mode.automatic
    @State private var title = ""
    @State private var symbolName = ""
    @State private var symbolQuery = ""
    @State private var symbolResults: [String] = []
    @State private var emoji = ""
    @State private var pictureName: String?
    @State private var loaded = false

    private var symbolIsValid: Bool {
        !symbolName.isEmpty && NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Name and Icon").font(.headline)
            TextField("Name", text: $title, prompt: Text(defaultTitle))
                .textFieldStyle(.roundedBorder)
            Picker("Icon", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch mode {
            case .automatic:
                Text(id.hasPrefix("folder-") ? "The folder's own icon." : "The action's own icon.")
                    .font(.callout).foregroundStyle(.secondary)
            case .symbol:
                HStack {
                    Image(systemName: symbolIsValid ? symbolName : "questionmark.square.dashed")
                        .font(.system(size: 20)).frame(width: 28)
                        .foregroundStyle(symbolIsValid ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    TextField("Search symbols (star, wifi, folder…)", text: $symbolQuery)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(38), spacing: 6), count: 9), spacing: 6) {
                        ForEach(symbolResults, id: \.self) { name in
                            Button { symbolName = name } label: {
                                Image(systemName: name).font(.system(size: 17)).frame(width: 36, height: 34)
                                    .background(symbolName == name ? AnyShapeStyle(.tint.opacity(0.28)) : AnyShapeStyle(.clear),
                                                in: .rect(cornerRadius: 7))
                            }
                            .buttonStyle(.plain)
                            .help(name)
                        }
                    }
                    .padding(2)
                    if symbolResults.isEmpty {
                        Text("No symbol matches “\(symbolQuery)”.").font(.callout).foregroundStyle(.secondary).padding(.top, 20)
                    }
                }
                .frame(height: 170)
                .background(.primary.opacity(0.05), in: .rect(cornerRadius: 10))
                Text(symbolName.isEmpty ? String(localized: "Names match what the SF Symbols app shows.") : symbolName)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            case .emoji:
                TextField("Paste or type an emoji", text: $emoji)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 22))
                    .onChange(of: emoji) { _, new in if new.count > 2 { emoji = String(new.prefix(1)) } }
                Button("Show Emoji Picker") { NSApp.orderFrontCharacterPalette(nil) }
                    .buttonStyle(.link)
            case .picture:
                HStack {
                    if let pictureName, let image = IconStore.load(pictureName) {
                        Image(nsImage: image).resizable().frame(width: 36, height: 36)
                    }
                    Button("Choose Picture…") { choosePicture() }
                }
                Text("PNG, JPEG, HEIC or SVG-like images work; it's scaled to fit.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if id.hasPrefix("folder-") && mode != .automatic {
                Text("The icon is printed on the folder.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack {
                Button("Reset") { reset() }
                    .disabled(store.config.itemStyles[id] == nil)
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400, height: 470)
        .onAppear { load(); runSearch() }
        .onChange(of: title) { apply() }
        .onChange(of: mode) { apply() }
        .onChange(of: symbolName) { apply() }
        .onChange(of: symbolQuery) { runSearch() }
        .onChange(of: emoji) { apply() }
        .onChange(of: pictureName) { apply() }
    }

    /// Typed names that aren't in the catalogue (a custom symbol, say) still work when pasted into the field.
    private func runSearch() {
        let exact = symbolQuery.trimmingCharacters(in: .whitespaces)
        var found = SymbolCatalog.search(exact).filter(SymbolCatalog.isAvailable)
        if SymbolCatalog.isAvailable(exact), !found.contains(exact) { found.insert(exact, at: 0) }
        symbolResults = found
        // Typing a complete symbol name selects it.
        if SymbolCatalog.isAvailable(exact) { symbolName = exact }
    }

    private func load() {
        let style = store.config.itemStyles[id]
        title = style?.title ?? ""
        switch style?.icon {
        case .symbol(let name)?: mode = .symbol; symbolName = name
        case .emoji(let value)?: mode = .emoji; emoji = value
        case .image(let file)?: mode = .picture; pictureName = file
        case nil: mode = .automatic
        }
        DispatchQueue.main.async { loaded = true }
    }

    private func apply() {
        guard loaded else { return }
        var style = ItemStyle(title: title.isEmpty ? nil : title, icon: nil)
        switch mode {
        case .automatic: break
        case .symbol: if symbolIsValid { style.icon = .symbol(symbolName) }
        case .emoji: if !emoji.isEmpty { style.icon = .emoji(emoji) }
        case .picture: if let pictureName { style.icon = .image(pictureName) }
        }
        if style.isEmpty { store.config.itemStyles[id] = nil } else { store.config.itemStyles[id] = style }
    }

    private func reset() {
        title = ""; symbolName = ""; emoji = ""; pictureName = nil; mode = .automatic
        store.config.itemStyles[id] = nil
    }

    private func choosePicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let name = IconStore.importImage(from: url) else { return }
        pictureName = name
    }
}

// MARK: Shortcuts

/// Lists the shortcuts from the Shortcuts app so one can be added to a ring.
struct ShortcutPicker: View {
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var names: [String]?
    @State private var query = ""

    private var filtered: [String] {
        guard let names else { return [] }
        return query.isEmpty ? names : names.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add a Shortcut").font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding(16)
            TextField("Search", text: $query).textFieldStyle(.roundedBorder).padding(.horizontal, 16)

            Group {
                if let names {
                    if names.isEmpty {
                        ContentUnavailableView("No shortcuts found", systemImage: "bolt.slash",
                                               description: Text("Create one in the Shortcuts app, then come back."))
                    } else {
                        List(filtered, id: \.self) { name in
                            Button { onPick(name); dismiss() } label: {
                                Label(name, systemImage: "bolt.fill").frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: 360, height: 420)
        .task { names = await ShortcutLibrary.names() }
    }
}

// MARK: Reordering by dragging

/// What is carried while a row is dragged: the row's id. Its own type, so text fields never take it as a drop.
private struct DraggedRow: Transferable {
    let id: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(contentType: .data) { Data($0.id.utf8) } importing: { DraggedRow(id: String(decoding: $0, as: UTF8.self)) }
    }
}

private struct ReorderModifier: ViewModifier {
    let id: String
    let number: Int
    let move: (_ dragged: String, _ onto: String) -> Void
    @State private var targeted = false

    func body(content: Content) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)
                .help("Drag to reorder")
            // Where the item sits on the ring: 1 is at the top, the rest follow clockwise.
            Text("\(number)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(.quaternary, in: .circle)
                .help("Position on the ring: 1 is at the top, then clockwise")
            content
        }
            .draggable(DraggedRow(id: id))
            .dropDestination(for: DraggedRow.self) { rows, _ in
                guard let dragged = rows.first?.id, dragged != id else { return false }
                withAnimation(.smooth(duration: 0.2)) { move(dragged, id) }
                return true
            } isTargeted: { targeted = $0 }
            .background { if targeted { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.tint.opacity(0.18)) } }
            .animation(.smooth(duration: 0.15), value: targeted)
    }
}

extension View {
    /// The row can be dragged onto another row of the same list, and takes the place of that row.
    func reorderable(id: String, number: Int, move: @escaping (_ dragged: String, _ onto: String) -> Void) -> some View {
        modifier(ReorderModifier(id: id, number: number, move: move))
    }
}

extension Array {
    /// Takes the element with id `item` out and puts it where the element with id `target` is.
    mutating func move(_ item: String, onto target: String, id: (Element) -> String) {
        guard let from = firstIndex(where: { id($0) == item }), let to = firstIndex(where: { id($0) == target }), from != to else { return }
        insert(remove(at: from), at: to)
    }
}

/// A small ring that shows how the numbers beside the rows go round it: 1 at the top, then clockwise.
struct RingOrderHint: View {
    let count: Int

    var body: some View {
        let side = max(92, CGFloat(count) * 11)
        let radius = side / 2 - 11
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 1).frame(width: radius * 2, height: radius * 2)
            Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .medium)).foregroundStyle(.tertiary)
            ForEach(0..<max(count, 1), id: \.self) { index in
                let angle = 2 * Double.pi * Double(index) / Double(max(count, 1))
                Text("\(index + 1)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(index == 0 ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .frame(width: 20, height: 20)
                    .background(index == 0 ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: .circle)
                    .offset(x: CGFloat(sin(angle)) * radius, y: -CGFloat(cos(angle)) * radius)
            }
        }
        .frame(width: side, height: side)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}
