import AppKit
import Observation

/// A Telegram chat pinned next to the apps: opens straight into that conversation.
struct TelegramChat: Codable, Hashable, Identifiable {
    var id = UUID()
    var title: String
    /// A `tg://` link that Telegram opens directly.
    var link: String

    /// Turns what people paste into a `tg://` link: `@name`, `t.me/name`, a phone number (+380…), or a numeric user id.
    static func link(from input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("tg://") { return URL(string: text) == nil ? nil : text }
        for prefix in ["https://t.me/", "http://t.me/", "t.me/", "https://telegram.me/", "telegram.me/", "@"] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
            break
        }
        text = text.components(separatedBy: CharacterSet(charactersIn: "/?#")).first ?? text
        guard !text.isEmpty else { return nil }
        let digits = text.filter(\.isNumber)
        if text.hasPrefix("+") && digits.count >= 7 { return "tg://resolve?phone=\(digits)" }
        if text.allSatisfy(\.isNumber) { return "tg://user?id=\(text)" }
        let valid = text.count >= 4 && text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        return valid ? "tg://resolve?domain=\(text)" : nil
    }

    var url: URL? { URL(string: link) }

    /// The public username, when the link has one (phone numbers and ids have no public page to read a picture from).
    var username: String? {
        URLComponents(string: link)?.queryItems?.first { $0.name == "domain" }?.value
    }

    /// Telegram's own icon, when it is installed (the stock one and the Desktop build).
    static var appIcon: NSImage? {
        for id in ["ru.keepcoder.Telegram", "org.telegram.desktop"] {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return NSWorkspace.shared.icon(forFile: url.path) }
        }
        return nil
    }
}

/// Chats shown by the Apps tile after the pinned apps. Kept in UserDefaults; edited in Settings → Rings → Pop-up.
@MainActor @Observable
final class TelegramChats {
    static let shared = TelegramChats()

    private static let key = "pinnedTelegramChats"

    var items: [TelegramChat] {
        didSet { if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: Self.key) } }
    }

    /// Profile pictures read from the chats' public pages, round, by chat id.
    private(set) var avatars: [UUID: NSImage] = [:]
    /// Pictures the user chose; they win over the ones read from Telegram.
    private(set) var customAvatars: [UUID: NSImage] = [:]

    private static var avatarDirectory: URL { URL.applicationSupportDirectory.appendingPathComponent("Shiftio/telegram-avatars") }

    init() {
        items = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([TelegramChat].self, from: $0) } ?? []
        // `-ShiftioDemoChats`: made-up chats for screenshots (nothing is read from Telegram or saved).
        if ProcessInfo.processInfo.arguments.contains("-ShiftioDemoChats") {
            items = [("Mom", "mom_demo"), ("Alex", "alex_demo"), ("Design team", "design_demo")].map {
                TelegramChat(title: $0.0, link: "tg://resolve?domain=\($0.1)")
            }
            return
        }
        for chat in items {
            if let image = NSImage(contentsOf: Self.avatarDirectory.appendingPathComponent(chat.id.uuidString + ".png")) { avatars[chat.id] = image }
        }
        for chat in items {
            if let image = NSImage(contentsOf: Self.customURL(chat)) { customAvatars[chat.id] = image }
        }
        for chat in items where avatars[chat.id] == nil { loadAvatar(of: chat) }
    }

    func add(title: String, input: String) -> Bool {
        guard let link = TelegramChat.link(from: input) else { return false }
        let chat = TelegramChat(title: title.trimmingCharacters(in: .whitespacesAndNewlines), link: link)
        items.append(chat)
        loadAvatar(of: chat)
        return true
    }

    func remove(_ chat: TelegramChat) {
        items.removeAll { $0.id == chat.id }
        avatars[chat.id] = nil
        customAvatars[chat.id] = nil
        try? FileManager.default.removeItem(at: Self.avatarDirectory.appendingPathComponent(chat.id.uuidString + ".png"))
        try? FileManager.default.removeItem(at: Self.customURL(chat))
    }

    private static func customURL(_ chat: TelegramChat) -> URL {
        avatarDirectory.appendingPathComponent(chat.id.uuidString + "-custom.png")
    }

    func hasCustomAvatar(_ chat: TelegramChat) -> Bool { customAvatars[chat.id] != nil }

    /// Uses a picture from disk for this chat (cropped to a circle), or goes back to Telegram's when `file` is nil.
    func setCustomAvatar(_ file: URL?, for chat: TelegramChat) {
        guard let file else {
            customAvatars[chat.id] = nil
            try? FileManager.default.removeItem(at: Self.customURL(chat))
            return
        }
        guard let picture = NSImage(contentsOf: file), let round = Self.circular(picture),
              let tiff = round.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(at: Self.avatarDirectory, withIntermediateDirectories: true)
        try? png.write(to: Self.customURL(chat))
        customAvatars[chat.id] = round
    }

    /// The chat's own picture, or Telegram's icon when it has none (or isn't public).
    func image(for chat: TelegramChat) -> NSImage? { customAvatars[chat.id] ?? avatars[chat.id] ?? TelegramChat.appIcon }

    /// Reads the picture from `t.me/<username>` (its link preview image). Silent when offline or when there is none.
    private func loadAvatar(of chat: TelegramChat) {
        guard let name = chat.username, let page = URL(string: "https://t.me/" + name) else { return }
        Task {
            guard let (html, _) = try? await URLSession.shared.data(from: page),
                  let text = String(data: html, encoding: .utf8),
                  let range = text.range(of: #"property="og:image" content="([^"]+)""#, options: .regularExpression) else { return }
            let match = String(text[range])
            guard let start = match.range(of: #"content=""#)?.upperBound,
                  let source = URL(string: String(match[start...].dropLast())), !source.absoluteString.contains("t_logo"),
                  let (data, _) = try? await URLSession.shared.data(from: source),
                  let picture = NSImage(data: data), let round = Self.circular(picture) else { return }
            avatars[chat.id] = round
            if let tiff = round.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? FileManager.default.createDirectory(at: Self.avatarDirectory, withIntermediateDirectories: true)
                try? png.write(to: Self.avatarDirectory.appendingPathComponent(chat.id.uuidString + ".png"))
            }
        }
    }

    private static func circular(_ source: NSImage, side: CGFloat = 128) -> NSImage? {
        guard source.size.width > 0, source.size.height > 0 else { return nil }
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: side, height: side)).addClip()
        let scale = side / min(source.size.width, source.size.height)
        let size = NSSize(width: source.size.width * scale, height: source.size.height * scale)
        source.draw(in: NSRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
        image.unlockFocus()
        return image
    }
}
