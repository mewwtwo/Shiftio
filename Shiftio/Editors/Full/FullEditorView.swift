import AppKit
import SwiftUI

/// The Edit window: picture on the left, tools on the right, actions along the top.
struct FullEditorView: View {
    @Environment(\.colorScheme) private var colorScheme
    let tint: Color
    let onClose: () -> Void
    let onFinish: @MainActor (Result<[URL], Error>) -> Void

    @State private var model: FullEditorModel
    @State private var showExport = false

    init(image: EditableImage, tint: Color, onClose: @escaping () -> Void,
         onFinish: @escaping @MainActor (Result<[URL], Error>) -> Void) {
        self.tint = tint
        self.onClose = onClose
        self.onFinish = onFinish
        _model = State(initialValue: FullEditorModel(image: image))
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                topBar
                EditorCanvas(model: model, tint: tint)
            }
            EditorInspector(model: model, tint: tint)
                .frame(width: 316)
                .padding(.vertical, 10)
                .padding(.trailing, 10)
                .padding(.leading, 4)
        }
        // The window is glass like the other editors, not a black sheet.
        .background { Rectangle().fill(.black.opacity(colorScheme == .dark ? 0.16 : 0)).glassEffect(.regular, in: .rect).ignoresSafeArea() }
        .ignoresSafeArea()
        .tint(tint)
        .background { shortcuts }
        .touchBar {
            ForEach(FullEditorModel.Tool.allCases) { tool in
                Button { model.select(tool) } label: { Image(systemName: tool.symbol) }
            }
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
            Button("Save") { saveCopy() }
        }
        .alert("Couldn't save", isPresented: Binding(get: { model.errorMessage != nil },
                                                    set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 10) {
                Color.clear.frame(width: 76)   // room for the window's traffic lights

                BarGroup {
                    BarButton(symbol: "arrow.uturn.backward", help: "Undo (⌘Z)", enabled: model.canUndo) { model.undo() }
                    BarButton(symbol: "arrow.uturn.forward", help: "Redo (⇧⌘Z)", enabled: model.canRedo) { model.redo() }
                    BarButton(symbol: "arrow.counterclockwise", help: "Discard all edits", enabled: !model.state.isUntouched) {
                        withAnimation(.smooth) { model.revertAll() }
                    }
                }

                Spacer(minLength: 8)
                Text(model.image.url.lastPathComponent)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)

                compareButton
                zoomMenu
                BarGroup {
                    BarButton(symbol: "square.and.arrow.up", help: "Export options") { showExport.toggle() }
                        .popover(isPresented: $showExport, arrowEdge: .bottom) {
                            ExportPanel(model: model, tint: tint, saveCopy: {
                                showExport = false
                                saveCopy()
                            }, replaceOriginal: {
                                showExport = false
                                replaceOriginal()
                            })
                        }
                }

                Button { saveCopy() } label: {
                    Group {
                        if model.isSaving { ProgressView().controlSize(.small) } else { Text("Save") }
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 52, minHeight: 30)
                    .padding(.horizontal, 6)
                    .background(tint, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(model.isSaving)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
        .background { WindowDragArea() }
    }

    /// Hold to see the picture without your edits (same framing).
    private var compareButton: some View {
        HStack(spacing: 6) {
            Image(systemName: "eye")
            Text("Original")
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 13)
        .frame(height: 32)
        .background(.primary.opacity(0.1), in: Capsule())
        .onLongPressGesture(minimumDuration: 60, maximumDistance: 200, perform: {}, onPressingChanged: { pressing in
            model.setComparing(pressing)
        })
        .help("Hold to compare with the original")
    }

    private var zoomMenu: some View {
        Menu {
            Button("Fit") { setZoom(1) }
            Button("150%") { setZoom(1.5) }
            Button("200%") { setZoom(2) }
            Button("400%") { setZoom(4) }
            Divider()
            Button("Actual Pixels") { setZoom(1 / (model.fitScale * (NSScreen.main?.backingScaleFactor ?? 2))) }
        } label: {
            Text(model.zoom == 1 ? String(localized: "Fit") : "\(Int((model.zoom * 100).rounded()))%")
                .font(.system(size: 12, weight: .medium)).monospacedDigit()
                .frame(minWidth: 34)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(.primary.opacity(0.1), in: Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Zoom")
    }

    private func setZoom(_ value: Double) {
        withAnimation(.smooth(duration: 0.25)) { model.zoom = min(8, max(0.5, value)) }
        model.refresh()
    }

    // MARK: Saving

    private func saveCopy() {
        Task {
            if let url = await model.save(replacingOriginal: false) { onFinish(.success([url])) }
        }
    }

    private func replaceOriginal() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Replace the original?")
        alert.informativeText = String(localized: "\(model.image.url.lastPathComponent) will be moved to the Trash and the edited picture saved in its place.")
        alert.addButton(withTitle: String(localized: "Replace"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            if let url = await model.save(replacingOriginal: true) { onFinish(.success([url])) }
        }
    }

    private var shortcuts: some View {
        Group {
            Button("Undo") { model.undo() }.keyboardShortcut("z")
            Button("Redo") { model.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
            Button("Save") { saveCopy() }.keyboardShortcut("s")
            Button("Close") { onClose() }.keyboardShortcut("w")
        }
        .opacity(0)
        .accessibilityHidden(true)
    }
}

/// A flat pill holding a few round toolbar buttons.
private struct BarGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) { content }
            .padding(.horizontal, 3)
            .frame(height: 32)
            .background(.primary.opacity(0.1), in: Capsule())
    }
}

private struct BarButton: View {
    let symbol: String
    let help: LocalizedStringKey
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 26)
                .background(.primary.opacity(hovering && enabled ? 0.12 : 0), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(help)
    }
}
