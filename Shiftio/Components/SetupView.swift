import AppKit
import SwiftUI

/// One line of the setup list: a name, what it's for, and how far along it is.
struct ComponentRow: View {
    enum Status {
        case waiting
        case working(String)
        case done(String)
        case failed(String)
    }

    let title: String
    let detail: String
    let status: Status
    var retry: (() -> Void)?

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                switch status {
                case .waiting: Image(systemName: "circle.dotted").foregroundStyle(.secondary)
                case .working: ProgressView().controlSize(.small)
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            .font(.system(size: 20))
            .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(statusText).font(.system(size: 11)).foregroundStyle(statusColor).lineLimit(2)
            }
            Spacer(minLength: 8)
            if case .failed = status, let retry { Button("Retry", action: retry) }
        }
        .padding(12)
        .background(.primary.opacity(0.06), in: .rect(cornerRadius: 12, style: .continuous))
        .animation(.smooth(duration: 0.25), value: statusText)
    }

    private var statusText: String {
        switch status {
        case .waiting: detail
        case .working(let text), .done(let text): text.isEmpty ? detail : text
        case .failed(let message): message
        }
    }

    private var statusColor: Color {
        if case .failed = status { return .orange }
        return .secondary
    }
}

extension ComponentInstaller.State {
    var rowStatus: ComponentRow.Status {
        switch self {
        case .checking: .waiting
        case .missing: .waiting
        case .installing(let text): .working(text)
        case .installed: .done(String(localized: "Installed"))
        case .failed(let message): .failed(message)
        }
    }
}

extension SpeechAssets.Status {
    var rowStatus: ComponentRow.Status {
        switch self {
        case .checking: .waiting
        case .missing: .waiting
        case .downloading: .working(String(localized: "Downloading…"))
        case .installed: .done(String(localized: "Installed"))
        case .unsupported: .done(String(localized: "Not needed for this language"))
        case .failed(let message): .failed(message)
        }
    }
}

/// Shown the first time Shiftio opens: it fetches what isn't inside the app, then gets out of the way.
struct SetupView: View {
    let components: ComponentInstaller
    let speech: SpeechAssets
    let onClose: () -> Void

    private var isFinished: Bool {
        let mp3Done = components.mp3 == .installed
        let speechDone = speech.status == .installed || speech.status == .unsupported
        return mp3Done && speechDone
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
            VStack(spacing: 4) {
                Text(isFinished ? "Shiftio is ready" : "Setting up Shiftio").font(.title2.weight(.semibold))
                Text(isFinished ? "Drag a file, press ⇧, and drop it on an action."
                                : "One-time download of the extras Shiftio uses. This only happens now.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }

            VStack(spacing: 10) {
                ComponentRow(title: String(localized: "MP3 encoder"), detail: String(localized: "Needed to convert audio to MP3"),
                             status: components.mp3.rowStatus) { Task { await components.installMP3() } }
                ComponentRow(title: String(localized: "Speech recognition"), detail: String(localized: "Apple's on-device model, for transcripts and subtitles"),
                             status: speech.status.rowStatus) { Task { await speech.install() } }
            }

            Spacer(minLength: 0)
            Button(isFinished ? "Get Started" : "Continue in Background", action: onClose)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
        .padding(28)
        .frame(width: 460, height: 440)
        .animation(.smooth(duration: 0.3), value: isFinished)
        .task { speech.prepareInBackground() }
    }
}

@MainActor
final class SetupWindowController {
    private var window: NSWindow?

    func show(components: ComponentInstaller, speech: SpeechAssets) {
        if window == nil {
            let window = ActiveLookWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = String(localized: "Welcome to Shiftio")
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(
                rootView: SetupView(components: components, speech: speech) { [weak window] in window?.close() }.keepsActiveLook())
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
