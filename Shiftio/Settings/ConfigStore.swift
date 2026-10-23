import AppKit
import Foundation
import Observation
import SwiftUI

enum TriggerModifier: String, Codable, CaseIterable, Identifiable {
    case shift, option, control

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .shift: .shift
        case .option: .option
        case .control: .control
        }
    }
}

/// Modifier combinations that open a pop-up ring when held for a moment (nothing else pressed).
enum ChordTrigger: String, Codable, CaseIterable, Identifiable {
    case cmdShift, optShift, ctrlShift, cmdOpt, cmdCtrl, optCtrl

    var id: String { rawValue }

    var flags: NSEvent.ModifierFlags {
        switch self {
        case .cmdShift: [.command, .shift]
        case .optShift: [.option, .shift]
        case .ctrlShift: [.control, .shift]
        case .cmdOpt: [.command, .option]
        case .cmdCtrl: [.command, .control]
        case .optCtrl: [.option, .control]
        }
    }

    var title: String {
        switch self {
        case .cmdShift: "⌘⇧"
        case .optShift: "⌥⇧"
        case .ctrlShift: "⌃⇧"
        case .cmdOpt: "⌘⌥"
        case .cmdCtrl: "⌘⌃"
        case .optCtrl: "⌥⌃"
        }
    }
}

struct RGBAColor: Codable, Hashable {
    var red, green, blue, alpha: Double

    static let orange = RGBAColor(red: 0.95, green: 0.42, blue: 0.18, alpha: 1)

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }

    init(red: Double, green: Double, blue: Double, alpha: Double) {
        (self.red, self.green, self.blue, self.alpha) = (red, green, blue, alpha)
    }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .orange
        self.init(red: ns.redComponent, green: ns.greenComponent, blue: ns.blueComponent, alpha: ns.alphaComponent)
    }
}

/// How Liquid Glass surfaces are drawn. Reduce Transparency in macOS always wins and forces solid.
enum GlassStyle: String, Codable, CaseIterable, Identifiable {
    case system, clear, frosted, solid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: String(localized: "Follow macOS")
        case .clear: String(localized: "Clear")
        case .frosted: String(localized: "Frosted")
        case .solid: String(localized: "Solid")
        }
    }
}

/// The look of the app's own surfaces (rings, player, editors, settings): dark, light, or whatever macOS is set to.
enum AppTheme: String, Codable, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: String(localized: "Follow system")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }

    @MainActor func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

struct Appearance: Codable, Hashable {
    /// Off gives a neutral, colourless interface (gray highlights instead of the accent).
    var accentEnabled = true
    /// Follows System Settings → Appearance → Accent colour, like built-in apps.
    var useSystemAccent = true
    var tint = RGBAColor.orange
    /// 0.2 (very soft) … 1 (full colour). Softening desaturates and fades the accent.
    var accentIntensity = 0.6
    var theme = AppTheme.system
    var glassStyle = GlassStyle.clear
    /// 0 (light blur) … 1 (heavy blur); only used by the Frosted style.
    var glassFrost = 0.5
    /// How much accent colour the glass picks up: 0 is water-clear, higher is more tinted.
    var glassTint = 0.1
    var diameter: Double = 340
    var showIcons = true
    var showLabels = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accentEnabled = try c.decodeIfPresent(Bool.self, forKey: .accentEnabled) ?? true
        useSystemAccent = try c.decodeIfPresent(Bool.self, forKey: .useSystemAccent) ?? true
        tint = try c.decodeIfPresent(RGBAColor.self, forKey: .tint) ?? .orange
        accentIntensity = try c.decodeIfPresent(Double.self, forKey: .accentIntensity) ?? 0.6
        theme = try c.decodeIfPresent(AppTheme.self, forKey: .theme) ?? .system
        glassStyle = try c.decodeIfPresent(GlassStyle.self, forKey: .glassStyle) ?? .clear
        glassFrost = try c.decodeIfPresent(Double.self, forKey: .glassFrost) ?? 0.5
        glassTint = try c.decodeIfPresent(Double.self, forKey: .glassTint) ?? 0.1
        // Configs saved before the tint setting existed carry the old "follow macOS" default, which looked matte.
        if !c.contains(.glassTint) { glassStyle = .clear }
        diameter = try c.decodeIfPresent(Double.self, forKey: .diameter) ?? 340
        showIcons = try c.decodeIfPresent(Bool.self, forKey: .showIcons) ?? true
        showLabels = try c.decodeIfPresent(Bool.self, forKey: .showLabels) ?? true
    }

    private var base: Color { useSystemAccent ? Color(nsColor: .controlAccentColor) : tint.color }

    /// The colour used for highlights, selected states and tints across the app.
    var accent: Color {
        guard accentEnabled else { return Color(white: 0.55) }
        let soften = 1 - accentIntensity
        return base.mix(with: Color(white: 0.6), by: soften * 0.45).opacity(0.55 + 0.45 * accentIntensity)
    }

    var nsAccent: NSColor { NSColor(accent) }

    var glass: GlassSettings { GlassSettings(style: glassStyle, frost: glassFrost, tint: glassTint) }
}

struct AppConfig: Codable {
    var enabled = true
    var trigger = TriggerModifier.shift
    var hideOnModifierRelease = false
    var revealInFinder = false
    var appearance = Appearance()
    var rings = RingConfig.defaults
    var ringsVersion = RingConfig.defaultsVersion
    var audioFormat = AudioFormat.mp3
    var mp3Bitrate = 192
    /// Hold ⌘⇧ to open the ring of system controls.
    var controlRingEnabled = true
    var controlRingDelay = 0.3
    /// Music player above the System ring.
    var nowPlayingEnabled = true
    /// A Recent ring of the tools last and most used on files, ahead of the others.
    var recentRingEnabled = true
    /// Custom name and icon per ring item, keyed by the item's id.
    var itemStyles: [String: ItemStyle] = [:]

    init() {}

    var actionOptions: ActionOptions {
        ActionOptions(audioFormat: audioFormat, mp3Bitrate: mp3Bitrate)
    }

    /// Tolerates missing keys so older config files keep their settings when fields are added.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        trigger = try c.decodeIfPresent(TriggerModifier.self, forKey: .trigger) ?? .shift
        hideOnModifierRelease = try c.decodeIfPresent(Bool.self, forKey: .hideOnModifierRelease) ?? false
        revealInFinder = try c.decodeIfPresent(Bool.self, forKey: .revealInFinder) ?? false
        appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance) ?? Appearance()
        rings = try c.decodeIfPresent([FileCategory: [RingConfig]].self, forKey: .rings) ?? RingConfig.defaults
        ringsVersion = try c.decodeIfPresent(Int.self, forKey: .ringsVersion) ?? 1
        audioFormat = try c.decodeIfPresent(AudioFormat.self, forKey: .audioFormat) ?? .mp3
        mp3Bitrate = try c.decodeIfPresent(Int.self, forKey: .mp3Bitrate) ?? 192
        controlRingEnabled = try c.decodeIfPresent(Bool.self, forKey: .controlRingEnabled) ?? true
        controlRingDelay = try c.decodeIfPresent(Double.self, forKey: .controlRingDelay) ?? 0.3
        nowPlayingEnabled = try c.decodeIfPresent(Bool.self, forKey: .nowPlayingEnabled) ?? true
        recentRingEnabled = try c.decodeIfPresent(Bool.self, forKey: .recentRingEnabled) ?? true
        itemStyles = try c.decodeIfPresent([String: ItemStyle].self, forKey: .itemStyles) ?? [:]
    }
}

@MainActor @Observable
final class ConfigStore {
    var config: AppConfig {
        didSet { save() }
    }

    private let url: URL
    /// Set by the app so rings can show recent and frequent apps.
    var appUsage: AppUsage?

    init(url: URL = ConfigStore.defaultURL) {
        self.url = url
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) {
            config = decoded
            if config.ringsVersion < 3 {
                config.rings = RingConfig.defaults
            } else {
                // Later versions only added rings (audio/video in 4, system controls in 5); keep the user's own.
                if config.ringsVersion < 4 { config.rings[.media] = RingConfig.defaults[.media] }
                // Version 6 replaced the system tiles (volume and brightness went away, tiles gained sub-rings).
                if config.ringsVersion < 6 { config.rings[.system] = RingConfig.defaults[.system] }
                // Version 7: pop-up rings got their own key combinations; the existing one keeps ⌘⇧.
                if config.ringsVersion < 7, config.rings[.system]?.contains(where: { $0.trigger != nil }) == false,
                   config.rings[.system]?.isEmpty == false {
                    config.rings[.system]?[0].trigger = .cmdShift
                }
                // Version 10: Night Shift made way for the Folders tile.
                if config.ringsVersion < 10, let rings = config.rings[.system] {
                    config.rings[.system] = rings.map { ring in
                        var ring = ring
                        ring.segments = ring.segments.map { $0 == "sys-nightshift" ? "sys-folders" : $0 }
                        return ring
                    }
                }
                // Version 9: the Display tile became a System Settings shortcut.
                if config.ringsVersion < 9, let rings = config.rings[.system] {
                    config.rings[.system] = rings.map { ring in
                        var ring = ring
                        ring.segments = ring.segments.map { $0 == "sys-display" ? "sys-settings" : $0 }
                        return ring
                    }
                }
                // Version 8: apps live in the System ring as tiles instead of a ring of their own.
                if config.ringsVersion < 8 {
                    config.rings[.system]?.removeAll { $0.segments == ["apps:recent:4", "apps:frequent:4"] }
                    if config.rings[.system]?.isEmpty == false {
                        for tile in ["sys-recentapps", "sys-frequentapps"]
                        where config.rings[.system]?.contains(where: { $0.segments.contains(tile) }) == false {
                            config.rings[.system]?[0].segments.append(tile)
                        }
                    }
                }
            }
            // Version 12: back to a 0.3 s hold, and the pop-up ring moves from ⌘⇧ (clashes with screenshots) to ⌥⇧.
            if config.ringsVersion < 12 {
                if config.controlRingDelay == 0.5 { config.controlRingDelay = 0.3 }
                config.rings[.system] = config.rings[.system]?.map { ring in
                    var ring = ring
                    if ring.trigger == .cmdShift { ring.trigger = .optShift }
                    return ring
                }
            }
            // Version 13: Recent and Frequent merged into one tile, and a pinned-apps tile was added.
            if config.ringsVersion < 13, let rings = config.rings[.system] {
                config.rings[.system] = rings.map { ring in
                    var ring = ring
                    var merged: [String] = []
                    for id in ring.segments {
                        let new = (id == "sys-recentapps" || id == "sys-frequentapps") ? "sys-suggestedapps" : id
                        if !merged.contains(new) { merged.append(new) }
                    }
                    if merged.contains("sys-suggestedapps"), !merged.contains("sys-apps") { merged.append("sys-apps") }
                    ring.segments = merged
                    return ring
                }
            }
            // Version 14: the video editor ("trim") joined the Media ring.
            if config.ringsVersion < 14, let rings = config.rings[.media], !rings.contains(where: { $0.segments.contains("trim") }),
               let index = rings.firstIndex(where: { $0.segments.contains("mp4") }) {
                config.rings[.media]?[index].segments.append("trim")
            }
            // Version 15: Compress takes audio and video too, and has its own window.
            if config.ringsVersion < 15, let rings = config.rings[.media], !rings.contains(where: { $0.segments.contains("compress") }),
               let index = rings.firstIndex(where: { $0.segments.contains("trim") || $0.segments.contains("mp4") }) {
                config.rings[.media]?[index].segments.append("compress")
            }
            // Version 16: Get Info joined the last ring of each file type.
            if config.ringsVersion < 16 {
                for category in [FileCategory.pdf, .image, .document, .media] {
                    guard var rings = config.rings[category], !rings.contains(where: { $0.segments.contains("info") }), !rings.isEmpty else { continue }
                    rings[rings.count - 1].segments.append("info")
                    config.rings[category] = rings
                }
            }
            // Version 18: Screenshot and Record Video are not in the pop-up ring by default (they are offered in the ring
            // editor). The two tiles an earlier build appended on its own are taken out again.
            if config.ringsVersion == 17, let rings = config.rings[.system] {
                config.rings[.system] = rings.map { ring in
                    var ring = ring
                    ring.segments.removeAll { $0 == "sys-screenshot" || $0 == "sys-record" }
                    return ring
                }
            }
            config.ringsVersion = RingConfig.defaultsVersion
        } else {
            config = AppConfig()
        }
    }

    static var defaultURL: URL {
        // `-ShiftioConfigFile <path>` runs on another config (screenshots use a fresh one, so nothing personal shows).
        if let path = UserDefaults.standard.string(forKey: "ShiftioConfigFile") { return URL(fileURLWithPath: path) }
        return URL.applicationSupportDirectory.appendingPathComponent("Shiftio/config.json")
    }

    /// Rings applicable to the dragged files, in configured order. Empty → don't show the menu.
    func rings(for files: [URL]) -> [ResolvedRing] {
        var categories: [FileCategory] = files.count > 1 ? [.batch] : []
        if let category = files.first.flatMap(FileCategory.init(url:)) { categories.append(category) }
        var rings = categories
            .flatMap { config.rings[$0] ?? [] }
            .compactMap { ResolvedRing($0, files: files, resolution: resolution) }
        // The Recent ring goes first, and is only worth opening with a few tools in it.
        if config.recentRingEnabled, !rings.isEmpty {
            let recent = RingConfig(name: "Recent", center: nil, segments: ["tools:recent:4", "tools:frequent:3"])
            if let ring = ResolvedRing(recent, files: files, resolution: resolution), ring.segments.count >= 2 { rings.insert(ring, at: 0) }
        }
        return rings
    }

    private var resolution: RingResolution {
        RingResolution(options: config.actionOptions, styles: config.itemStyles, apps: appUsage, tools: ToolUsage.shared)
    }

    /// Pop-up rings that have a key combination, with their current contents (toggle states read fresh).
    func popupRing(id: UUID) -> ResolvedRing? {
        guard let ring = config.rings[.system]?.first(where: { $0.id == id }) else { return nil }
        return ResolvedRing(ring, resolution: resolution) { action in
            if let control = action as? ControlAction { return control.isAvailable() }
            if let app = action as? AppAction { return app.url != nil }
            return action is ShortcutAction
        }
    }

    /// The combinations currently assigned, for the key monitor.
    var popupTriggers: [(id: UUID, trigger: ChordTrigger)] {
        (config.rings[.system] ?? []).compactMap { ring in ring.trigger.map { (ring.id, $0) } }
    }

    func resetRings() {
        config.rings = RingConfig.defaults
        config.ringsVersion = RingConfig.defaultsVersion
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(config).write(to: url, options: .atomic)
        } catch {
            NSLog("Shiftio: failed to save config: \(error)")
        }
    }
}
