import AppKit
import Foundation

/// How a ring item looks when the user has customised it: any icon, any name. Stored per item id.
enum ItemIcon: Codable, Equatable {
    /// An SF Symbol by name, exactly as typed in the SF Symbols app.
    case symbol(String)
    case emoji(String)
    /// A picture the user chose; the file name inside the app's Icons folder.
    case image(String)
}

struct ItemStyle: Codable, Equatable {
    var title: String?
    var icon: ItemIcon?

    var isEmpty: Bool { (title ?? "").isEmpty && icon == nil }
}

/// Pictures chosen as icons live in Application Support/Shiftio/Icons, scaled down.
enum IconStore {
    static var directory: URL { URL.applicationSupportDirectory.appendingPathComponent("Shiftio/Icons") }

    /// Copies `source` into the store as a 128 px PNG and returns its file name.
    static func importImage(from source: URL) -> String? {
        guard let image = NSImage(contentsOf: source), image.isValid else { return nil }
        let side: CGFloat = 128
        let scaled = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let ratio = min(side / image.size.width, side / image.size.height)
            let size = NSSize(width: image.size.width * ratio, height: image.size.height * ratio)
            image.draw(in: NSRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
            return true
        }
        guard let tiff = scaled.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return nil }
        let name = UUID().uuidString + ".png"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: directory.appendingPathComponent(name))
            return name
        } catch {
            return nil
        }
    }

    static func load(_ name: String) -> NSImage? {
        NSImage(contentsOf: directory.appendingPathComponent(name))
    }
}

/// What a ring item shows once its default look and the user's changes are combined.
struct ItemPresentation {
    var title: String
    var symbol: String?
    var emoji: String?
    var image: NSImage?
}

enum ItemCatalog {
    static func presentation(of action: any FileAction, style: ItemStyle?, options: ActionOptions = ActionOptions(),
                             isOn: Bool? = nil) -> ItemPresentation {
        var result = ItemPresentation(title: action.displayTitle(options: options), symbol: action.displaySymbol(isOn: isOn),
                                      emoji: nil, image: (action as? AppAction)?.icon)
        guard let style else { return result }
        if let title = style.title, !title.isEmpty { result.title = title }
        switch style.icon {
        case .symbol(let name)?: result.symbol = name; result.emoji = nil; result.image = nil
        case .emoji(let emoji)?: result.emoji = emoji; result.symbol = nil; result.image = nil
        case .image(let file)?: result.image = IconStore.load(file) ?? result.image; if result.image != nil { result.symbol = nil; result.emoji = nil }
        case nil: break
        }
        return result
    }

    /// `apps:recent:4` and `apps:frequent:4` stand for several apps at once.
    enum Dynamic {
        case recentApps(Int)
        case frequentApps(Int)
        /// The tools (actions) last used on files, and the ones used most.
        case recentTools(Int)
        case frequentTools(Int)
    }

    static func dynamic(_ id: String) -> Dynamic? {
        let parts = id.split(separator: ":")
        guard parts.count == 3, let count = Int(parts[2]) else { return nil }
        switch (parts[0], parts[1]) {
        case ("apps", "recent"): return .recentApps(count)
        case ("apps", "frequent"): return .frequentApps(count)
        case ("tools", "recent"): return .recentTools(count)
        case ("tools", "frequent"): return .frequentTools(count)
        default: return nil
        }
    }

    /// Name of an entry in a ring's list in Settings.
    static func rowTitle(_ id: String, styles: [String: ItemStyle]) -> String {
        switch dynamic(id) {
        case .recentApps(let n)?: return String(localized: "Recent apps (\(n))")
        case .frequentApps(let n)?: return String(localized: "Frequent apps (\(n))")
        case .recentTools(let n)?: return String(localized: "Recent tools (\(n))")
        case .frequentTools(let n)?: return String(localized: "Frequent tools (\(n))")
        case nil:
            guard let action = ActionRegistry.action(id) else { return id }
            return presentation(of: action, style: styles[id]).title
        }
    }
}

/// A folder icon with the user's chosen glyph printed on it, like a custom folder in Finder.
enum FolderIcon {
    /// The soft darker-orange of the glyphs on Finder's own folder icons (Downloads, Documents…).
    static let glyphTone = NSColor(red: 0.55, green: 0.26, blue: 0.0, alpha: 0.5)

    /// `base` is the folder's own icon (or the generic one); the glyph sits on the lower body of the folder.
    static func make(base: NSImage, icon: ItemIcon, side: CGFloat = 128) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            base.draw(in: rect)
            // The folder's front face: centred a little below the middle.
            let glyph = NSRect(x: rect.midX - side * 0.19, y: rect.midY - side * 0.27, width: side * 0.38, height: side * 0.38)
            switch icon {
            case .symbol(let name):
                guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: side * 0.3, weight: .semibold)) else { return true }
                tinted(symbol, color: glyphTone).draw(in: fit(symbol.size, in: glyph))
            case .emoji(let value):
                let font = NSFont.systemFont(ofSize: side * 0.3)
                let text = NSAttributedString(string: value, attributes: [.font: font])
                let size = text.size()
                text.draw(at: NSPoint(x: glyph.midX - size.width / 2, y: glyph.midY - size.height / 2))
            case .image(let file):
                guard let picture = IconStore.load(file) else { return true }
                picture.draw(in: fit(picture.size, in: glyph))
            }
            return true
        }
    }

    /// Finder's own Desktop icon has a heavier, darker glyph than Downloads, Documents and Applications. This draws the
    /// generic folder with a glyph in the same soft tone-on-tone style as those.
    static func desktop(side: CGFloat = 128) -> NSImage {
        let base = NSWorkspace.shared.icon(for: .folder)
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            base.draw(in: rect)
            let glyph = NSRect(x: rect.midX - side * 0.21, y: rect.midY - side * 0.28, width: side * 0.42, height: side * 0.42)
            guard let symbol = NSImage(systemSymbolName: "menubar.dock.rectangle", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: side * 0.34, weight: .regular)) else { return true }
            tinted(symbol, color: glyphTone).draw(in: fit(symbol.size, in: glyph))
            return true
        }
    }

    private static func fit(_ size: NSSize, in box: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height)
        let fitted = NSSize(width: size.width * scale, height: size.height * scale)
        return NSRect(x: box.midX - fitted.width / 2, y: box.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
    }

    private static func tinted(_ image: NSImage, color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceIn)
            return true
        }
    }

    /// The folder's own icon, or the generic folder for virtual entries such as Recents.
    static func baseIcon(for folder: PinnedFolder) -> NSImage {
        if let url = folder.url {
            if url.standardizedFileURL.path == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").path {
                return desktop()
            }
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .folder)
    }
}
