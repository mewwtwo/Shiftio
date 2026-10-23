import AppKit
import UniformTypeIdentifiers

/// Runs a shortcut from the Shortcuts app. In rings for files, the dragged files are handed to it as input.
struct ShortcutAction: FileAction {
    let name: String

    var id: String { "shortcut:" + name }
    var title: String { name }
    var symbol: String? { "bolt.fill" }
    var inputTypes: [UTType] { [.item] }

    func run(_ urls: [URL], options: ActionOptions) async throws -> [URL] {
        var arguments = ["run", name]
        for url in urls { arguments += ["-i", url.path] }
        try await Shell.runAsync("/usr/bin/shortcuts", arguments)
        return []
    }
}

enum ShortcutLibrary {
    /// Names of the user's shortcuts (`shortcuts list`), sorted.
    static func names() async -> [String] {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["list"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = Pipe()
            guard (try? process.run()) != nil else { return [] }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
                .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }.value
    }
}

/// Opens an app; dropped files are opened with it.
struct AppAction: FileAction {
    let bundleID: String

    var id: String { "app:" + bundleID }
    var inputTypes: [UTType] { [.item] }
    var symbol: String? { "app" }

    var url: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }

    var title: String {
        guard let url else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    var icon: NSImage? { url.map { NSWorkspace.shared.icon(forFile: $0.path) } }

    func run(_ urls: [URL], options: ActionOptions) async throws -> [URL] {
        guard let appURL = url else { throw ShiftioError.unavailable(bundleID) }
        let configuration = NSWorkspace.OpenConfiguration()
        if urls.isEmpty {
            try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        } else {
            try await NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: configuration)
        }
        return []
    }
}
