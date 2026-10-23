import ImageIO
import PDFKit
import QuickLookThumbnailing
import SwiftUI

/// Popover of the menubar item, laid out like a system menu-bar extra: a header with the main switch,
/// a short list of results, then menu-style commands.
/// Fades, rises and unblurs a section when the popover opens, one after another.
private struct Reveal: ViewModifier {
    let index: Int
    let shown: Bool

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 10)
            .blur(radius: shown ? 0 : 3)
            .animation(.spring(response: 0.42, dampingFraction: 0.82).delay(Double(index) * 0.045), value: shown)
    }
}

private extension View {
    func reveal(_ index: Int, _ shown: Bool) -> some View { modifier(Reveal(index: index, shown: shown)) }
}

struct MenuBarView: View {
    @Bindable var app: AppState
    @State private var shown = false

    var body: some View {
        VStack(spacing: 0) {
            header.reveal(0, shown)
            if let awake = app.keepAwake {
                Divider().padding(.horizontal, 10)
                KeepAwakeRow(endsAt: awake.endsAt)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            Divider().padding(.horizontal, 10)
            recents.reveal(1, shown)
            Divider().padding(.horizontal, 10)
            VStack(spacing: 0) {
                MenuRow(title: "Settings…", shortcut: "⌘,") {
                    NSApp.activate(ignoringOtherApps: true)
                    app.openSettings()
                }
                .keyboardShortcut(",")
                MenuRow(title: "Quit Shiftio", shortcut: "⌘Q") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .padding(6)
            .reveal(2, shown)
        }
        .frame(width: 320)
        .tint(Color(nsColor: .controlAccentColor))
        .animation(.smooth(duration: 0.25), value: app.recents.count)
        .animation(.smooth(duration: 0.25), value: app.keepAwake)
        .onAppear {
            app.hasUnseenError = false
            shown = true
        }
        .onDisappear { shown = false }
    }

    private var header: some View {
        HStack(spacing: 12) {
            // The petals in one colour: the selected one solid, the others lighter, like the menu bar icon.
            Image("HeaderGlyph")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.primary)
                .padding(7)
                .frame(width: 38, height: 38)
                .background(.primary.opacity(0.1), in: .rect(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text("Shiftio").font(.system(size: 13, weight: .semibold))
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 8)
            if app.runningCount > 0 { ProgressView().controlSize(.small) }
            Toggle("Enabled", isOn: $app.isEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .animation(.smooth(duration: 0.2), value: app.isEnabled)
    }

    private var status: String {
        if !app.isEnabled { return String(localized: "Paused") }
        if app.runningCount > 0 { return String(localized: "Working…") }
        return String(localized: "Drag a file and press \(app.store.config.trigger.glyph)")
    }

    @ViewBuilder
    private var recents: some View {
        if app.recents.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "tray")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("No recent files")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Recent")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(String(localized: "action.clear", defaultValue: "Clear")) { app.clearRecents() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.tint)
                        .help("Clear the list of recent files (the files themselves are not deleted)")
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 2)
                ForEach(app.recents.prefix(6)) { result in
                    RecentRow(result: result)
                        .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                                removal: .opacity))
                }
            }
            .padding(6)
            .padding(.top, 4)
        }
    }
}

private extension TriggerModifier {
    var glyph: String {
        switch self {
        case .shift: "⇧"
        case .option: "⌥"
        case .control: "⌃"
        }
    }
}

/// A menu-style row: full-width hit area, rounded highlight on hover.
private struct MenuRow: View {
    let title: LocalizedStringKey
    var shortcut: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 13))
                Spacer()
                if let shortcut {
                    Text(shortcut).font(.system(size: 12)).foregroundStyle(hovering ? .primary : .tertiary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(hovering ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .background(hovering ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6, style: .continuous))
        .scaleEffect(hovering ? 1.015 : 1)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: hovering)
    }
}

private struct RecentRow: View {
    let result: RecentResult
    @State private var hovering = false

    private var reveal: [URL] { result.outputs.isEmpty ? result.sources : result.outputs }

    var body: some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting(reveal)
        } label: {
            HStack(spacing: 10) {
                icon.frame(width: 28, height: 28)
                    .scaleEffect(hovering ? 1.1 : 1)
                    .animation(.spring(response: 0.28, dampingFraction: 0.6), value: hovering)
                VStack(alignment: .leading, spacing: 1) {
                    Text(result.outputs.first?.lastPathComponent ?? result.sources.first?.lastPathComponent ?? "")
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(result.error == nil ? .secondary : Color.red)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(.primary.opacity(hovering ? 0.08 : 0), in: .rect(cornerRadius: 8, style: .continuous))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(result.error ?? "Show in Finder")
    }

    @ViewBuilder
    private var icon: some View {
        if let first = result.outputs.first {
            FileThumbnail(url: first)
        } else {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.orange)
        }
    }

    private var subtitle: String {
        if let error = result.error { return error }
        let count = result.outputs.count > 1 ? String(localized: " · \(result.outputs.count) files") : ""
        let age = Date.now.timeIntervalSince(result.date) < 60
            ? String(localized: "just now")
            : RelativeDateTimeFormatter().localizedString(for: result.date, relativeTo: .now)
        return "\(result.actionTitle)\(count) · \(age)"
    }
}

/// Preview of the result: pictures and PDFs are drawn by the app itself (reliable for files that were just
/// written), anything else asks Quick Look; the file's icon is the fallback.
private struct FileThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(width: 28, height: 28)
                    .clipShape(.rect(cornerRadius: 5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(.primary.opacity(0.18), lineWidth: 0.5))
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
            }
        }
        .task(id: url) {
            let loaded = await Self.load(url)
            withAnimation(.easeOut(duration: 0.15)) { image = loaded }
        }
    }

    private static func load(_ url: URL) async -> NSImage? {
        if let direct = await Task.detached(priority: .utility, operation: { render(url) }).value { return direct }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 56, height: 56), scale: 2,
                                                   representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }

    private nonisolated static func render(_ url: URL) -> NSImage? {
        let side = 112
        if url.pathExtension.lowercased() == "pdf" {
            guard let page = PDFDocument(url: url)?.page(at: 0) else { return nil }
            return page.thumbnail(of: NSSize(width: side, height: side), for: .mediaBox)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: side]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
    }
}

/// Shown while Keep Awake is on: what it is, how long is left, and a way to stop it.
private struct KeepAwakeRow: View {
    let endsAt: Date?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(.tint, in: .rect(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text("Keep Awake").font(.system(size: 13, weight: .medium))
                TimelineView(.periodic(from: .now, by: 15)) { _ in
                    Text(remaining).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Stop") { KeepAwake.stop() }
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var remaining: String {
        guard let endsAt else { return String(localized: "Until you turn it off") }
        let minutes = max(0, Int((endsAt.timeIntervalSinceNow / 60).rounded(.up)))
        if minutes >= 60 { return String(localized: "\(minutes / 60) h \(minutes % 60) min left") }
        return String(localized: "\(max(1, minutes)) min left")
    }
}
