import AppKit
import Observation

/// Remembers which apps you switch to, for the "recent" and "frequent" app rings. macOS doesn't keep this
/// anywhere an app can read it, so Shiftio counts activations itself (kept in Application Support).
@MainActor @Observable
final class AppUsage {
    private struct Saved: Codable {
        var recent: [String]
        var counts: [String: Int]
    }

    /// One counter for the whole app, so the control ring's tiles can read it without being handed a reference.
    static let shared = AppUsage()

    private(set) var recentIDs: [String] = []
    private(set) var counts: [String: Int] = [:]
    private var saveTask: Task<Void, Never>?

    private static var fileURL: URL { URL.applicationSupportDirectory.appendingPathComponent("Shiftio/app-usage.json") }
    private static let ignored: Set<String> = ["com.apple.finder", "com.apple.dock", "com.apple.loginwindow"]

    init() {
        if let data = try? Data(contentsOf: Self.fileURL), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            recentIDs = saved.recent
            counts = saved.counts
        }
        if Self.isDemo {
            // `-ShiftioDemoApps`: a made-up history for screenshots; it is never written to disk.
            recentIDs = ["com.apple.Safari", "com.apple.mail", "com.apple.Notes", "com.apple.iCal", "com.apple.Music", "com.apple.MobileSMS"]
            counts = Dictionary(uniqueKeysWithValues: zip(recentIDs.reversed(), 1...))
        }
        if recentIDs.isEmpty {
            // First run: whatever is open now, newest first.
            recentIDs = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .sorted { ($0.launchDate ?? .distantPast) > ($1.launchDate ?? .distantPast) }
                .compactMap(\.bundleIdentifier)
                .filter(isTracked)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.record(app) }
        }
    }

    private static let isDemo = ProcessInfo.processInfo.arguments.contains("-ShiftioDemoApps")

    private func isTracked(_ id: String) -> Bool {
        id != Bundle.main.bundleIdentifier && !Self.ignored.contains(id)
    }

    func record(_ app: NSRunningApplication) {
        guard app.activationPolicy == .regular, let id = app.bundleIdentifier, isTracked(id) else { return }
        recentIDs.removeAll { $0 == id }
        recentIDs.insert(id, at: 0)
        if recentIDs.count > 40 { recentIDs.removeLast(recentIDs.count - 40) }
        counts[id, default: 0] += 1
        scheduleSave()
    }

    /// Forgets the recent and frequent apps. The list starts over as you switch apps.
    func clear() {
        recentIDs = []
        counts = [:]
        scheduleSave()
    }

    func recent(limit: Int) -> [String] { Array(installed(recentIDs).prefix(limit)) }

    func frequent(limit: Int) -> [String] {
        Array(installed(counts.sorted { $0.value > $1.value }.map(\.key)).prefix(limit))
    }

    private func installed(_ ids: [String]) -> [String] {
        ids.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    }

    private func scheduleSave() {
        guard !Self.isDemo else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            let saved = Saved(recent: recentIDs, counts: counts)
            try? FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(saved).write(to: Self.fileURL, options: .atomic)
        }
    }
}
