import AppKit

/// The language of Shiftio's own text. "System" follows macOS, and falls back to English when macOS is set to a language
/// Shiftio has not been translated into (the bundle lists exactly the languages below).
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, uk, es, pt, ja, zhHans = "zh-Hans", ko, fr, cs, it, id

    var id: String { rawValue }

    /// Each language in its own words, so it can be found whatever language the app is showing now.
    var nativeName: String {
        switch self {
        case .system: String(localized: "Same as system")
        case .en: "English"
        case .uk: "Українська"
        case .es: "Español"
        case .pt: "Português"
        case .ja: "日本語"
        case .zhHans: "简体中文"
        case .ko: "한국어"
        case .fr: "Français"
        case .cs: "Čeština"
        case .it: "Italiano"
        case .id: "Bahasa Indonesia"
        }
    }

    private static let defaultsKey = "appLanguage"

    static var chosen: AppLanguage {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(AppLanguage.init(rawValue:)) ?? .system }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            // macOS reads this list at launch to pick the language of the app's own text.
            if newValue == .system {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.set([newValue.rawValue], forKey: "AppleLanguages")
            }
        }
    }

    /// The language the running app actually shows (the system's when it is one of ours, otherwise English).
    static var shown: AppLanguage {
        let code = Bundle.main.preferredLocalizations.first ?? "en"
        return allCases.first { $0 != .system && code.hasPrefix($0.rawValue) } ?? .en
    }

    /// Starts a fresh copy of the app (language is fixed at launch) and quits this one.
    @MainActor
    static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.6; open -n \"\(Bundle.main.bundlePath)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}
