import AppKit
import Observation

/// The apps shown by the Apps tile, in the user's order. Kept in UserDefaults; edited in Settings → Rings → Pop-up.
@MainActor @Observable
final class AppPins {
    static let shared = AppPins()

    private static let key = "pinnedApps"

    var ids: [String] {
        didSet { UserDefaults.standard.set(ids, forKey: Self.key) }
    }

    init() {
        ids = UserDefaults.standard.stringArray(forKey: Self.key) ?? Self.defaults
    }

    /// Apps that ship with macOS, offered until the user pins their own.
    static var defaults: [String] {
        ["com.apple.Safari", "com.apple.mail", "com.apple.Notes", "com.apple.iCal", "com.apple.MobileSMS",
         "com.apple.Music", "com.apple.systempreferences", "com.apple.Terminal"]
            .filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    }

    func add(_ bundleID: String) {
        guard !ids.contains(bundleID) else { return }
        ids.append(bundleID)
    }
}

/// Which apps the merged Recent/Frequent tile shows.
enum SuggestedAppsMode: String, CaseIterable, Identifiable {
    case recent, frequent, mixed

    var id: String { rawValue }
    var title: String {
        switch self {
        case .recent: String(localized: "Recently used")
        case .frequent: String(localized: "Most used")
        case .mixed: String(localized: "Both")
        }
    }

    static let modeKey = "suggestedAppsMode"
    static let countKey = "suggestedAppsCount"

    static var current: SuggestedAppsMode {
        UserDefaults.standard.string(forKey: modeKey).flatMap(SuggestedAppsMode.init(rawValue:)) ?? .mixed
    }

    static var count: Int {
        let value = UserDefaults.standard.integer(forKey: countKey)
        return value == 0 ? 6 : min(max(value, 2), 10)
    }

    /// Bundle IDs for the tile; "both" alternates recent and frequent without repeats.
    @MainActor
    static func apps() -> [String] {
        let usage = AppUsage.shared, limit = count
        switch current {
        case .recent: return usage.recent(limit: limit)
        case .frequent: return usage.frequent(limit: limit)
        case .mixed:
            var result: [String] = []
            let recent = usage.recent(limit: limit), frequent = usage.frequent(limit: limit)
            for index in 0..<limit {
                for list in [recent, frequent] where index < list.count && !result.contains(list[index]) { result.append(list[index]) }
            }
            return Array(result.prefix(limit))
        }
    }
}
