import AppKit
import Foundation
import UniformTypeIdentifiers

enum FileCategory: String, Codable, CaseIterable, Identifiable, CodingKeyRepresentable {
    case batch, pdf, image, document, media, system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .batch: String(localized: "Multiple files")
        case .pdf: "PDF"
        case .image: String(localized: "Images")
        case .document: String(localized: "Documents")
        case .media: String(localized: "Audio & Video")
        case .system: String(localized: "Pop-up rings")
        }
    }

    /// Representative type used to list compatible actions in Settings.
    var sampleType: UTType {
        switch self {
        case .batch: .item
        case .pdf: .pdf
        case .image: .image
        case .document: .rtf
        case .media: .audiovisualContent
        case .system: .item
        }
    }

    init?(url: URL) {
        guard let type = UTType.of(url) else { return nil }
        if type.conforms(to: .pdf) { self = .pdf }
        else if type.conforms(to: .image) { self = .image }
        else if type.conforms(to: .audiovisualContent) { self = .media }
        else if [.rtf, .rtfd, .html, .plainText, .docx].contains(where: type.conforms(to:)) { self = .document }
        else { return nil }
    }
}

/// One ring of the radial menu as stored in the config. Pressing Shift again switches rings.
struct RingConfig: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var center: String?
    /// Pop-up rings only: hold this key combination to open the ring.
    var trigger: ChordTrigger?
    var segments: [String]
}

struct RingItem: Identifiable {
    let action: any FileAction
    let title: String
    let symbol: String?
    /// nil for ordinary actions; true/false for toggles, shown like Control Center's active tiles.
    let isOn: Bool?
    /// Custom looks: an emoji, or a picture (an app's own icon, or one the user chose).
    var emoji: String?
    var image: NSImage?
    var id: String { action.id }
}

/// Everything resolving a ring needs besides the ring itself.
struct RingResolution {
    var options = ActionOptions()
    var styles: [String: ItemStyle] = [:]
    var apps: AppUsage?
    var tools: ToolUsage?
}

/// A ring with action ids resolved and filtered for the dragged files.
struct ResolvedRing: Identifiable {
    let id: UUID
    let name: String
    let center: RingItem?
    let segments: [RingItem]

    init(name: String, center: RingItem?, segments: [RingItem]) {
        id = UUID()
        self.name = name
        self.center = center
        self.segments = segments
    }

    @MainActor
    init?(_ config: RingConfig, files: [URL], resolution: RingResolution = RingResolution()) {
        self.init(config, resolution: resolution) { action in
            files.count >= action.minimumFileCount && files.allSatisfy(action.accepts)
        }
    }

    @MainActor
    init?(_ config: RingConfig, resolution: RingResolution = RingResolution(), where isApplicable: (any FileAction) -> Bool) {
        func item(_ id: String) -> RingItem? {
            guard let action = ActionRegistry.action(id), isApplicable(action) else { return nil }
            let isOn = action.state()
            let look = ItemCatalog.presentation(of: action, style: resolution.styles[id], options: resolution.options, isOn: isOn)
            return RingItem(action: action, title: look.title, symbol: look.symbol, isOn: isOn, emoji: look.emoji, image: look.image)
        }
        /// "Recent apps (4)" and friends stand for several items.
        func resolve(_ id: String) -> [RingItem] {
            switch ItemCatalog.dynamic(id) {
            case .recentApps(let count)?:
                return (resolution.apps?.recent(limit: count) ?? []).compactMap { item("app:" + $0) }
            case .frequentApps(let count)?:
                return (resolution.apps?.frequent(limit: count) ?? []).compactMap { item("app:" + $0) }
            case .recentTools(let count)?:
                return (resolution.tools?.recent(limit: count, where: { item($0) != nil }) ?? []).compactMap(item)
            case .frequentTools(let count)?:
                return (resolution.tools?.frequent(limit: count, where: { item($0) != nil }) ?? []).compactMap(item)
            case nil:
                return item(id).map { [$0] } ?? []
            }
        }
        self.id = config.id
        name = RingConfig.displayName(config.name)
        center = config.center.flatMap { resolve($0).first }
        // A tool that is both recent and frequent shows once.
        var seen = Set<String>()
        segments = config.segments.flatMap(resolve).filter { seen.insert($0.action.id).inserted }
        if center == nil && segments.isEmpty { return nil }
    }
}

extension RingConfig {
    /// The built-in rings are saved with English names; they show in the app's language until the user renames them.
    static func displayName(_ name: String) -> String {
        switch name {
        case "Batch": String(localized: "Batch")
        case "Convert": String(localized: "Convert")
        case "Tools": String(localized: "Tools")
        case "Edit": String(localized: "Edit")
        case "Optimize": String(localized: "Optimize")
        case "Control": String(localized: "Control")
        case "Media": String(localized: "Media")
        case "Recent": String(localized: "Recent")
        case "New Ring": String(localized: "New Ring")
        default: name
        }
    }

    /// Bump when `defaults` change so saved configs pick up new actions.
    static let defaultsVersion = 18

    /// Centres are empty by default: dropping a file there cancels, like changing your mind.
    static let defaults: [FileCategory: [RingConfig]] = [
        .batch: [
            RingConfig(name: "Batch", center: nil, segments: ["merge-pdf", "zip", "jpg", "png", "compress"]),
        ],
        .pdf: [
            RingConfig(name: "Convert", center: nil, segments: ["jpg", "png", "docx", "txt", "rtf"]),
            RingConfig(name: "Tools", center: nil, segments: ["compress", "strip-metadata", "info"]),
        ],
        .image: [
            RingConfig(name: "Convert", center: nil, segments: ["jpg", "png", "heic", "pdf", "tiff", "gif"]),
            RingConfig(name: "Edit", center: nil, segments: ["crop", "edit", "add-bg", "annotate", "redact", "remove-bg"]),
            RingConfig(name: "Optimize", center: nil, segments: ["compress", "strip-metadata", "txt", "info"]),
        ],
        .document: [
            RingConfig(name: "Convert", center: nil, segments: ["docx", "rtf", "html", "txt", "info"]),
        ],
        .system: [
            RingConfig(name: "Control", center: nil, trigger: .optShift, segments: [
                "sys-wifi", "sys-bluetooth", "sys-appearance", "sys-keyboard", "sys-folders", "sys-keepawake", "sys-settings",
                "sys-suggestedapps", "sys-apps",
            ]),
        ],
        .media: [
            RingConfig(name: "Media", center: nil, segments: ["audio", "m4a", "wav", "transcribe", "srt", "mp4", "trim", "compress", "info"]),
        ],
    ]
}
