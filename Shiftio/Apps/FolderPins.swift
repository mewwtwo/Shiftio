import AppKit
import Observation

/// A folder pinned to the Folders tile. `recents` stands for Finder's Recents view.
struct PinnedFolder: Codable, Hashable, Identifiable {
    var id: String          // a path, or "recents"
    var title: String

    static let recentsID = "recents"
    var isRecents: Bool { id == Self.recentsID }
    var url: URL? { isRecents ? nil : URL(fileURLWithPath: id) }
}

/// The folders shown by the Folders tile. Kept in UserDefaults; edited in Settings → Rings → Pop-up.
@MainActor @Observable
final class FolderPins {
    static let shared = FolderPins()

    private static let key = "pinnedFolders"

    var items: [PinnedFolder] {
        didSet { save() }
    }

    static var defaults: [PinnedFolder] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            PinnedFolder(id: home + "/Desktop", title: String(localized: "Desktop")),
            PinnedFolder(id: home + "/Downloads", title: String(localized: "Downloads")),
            PinnedFolder(id: home + "/Documents", title: String(localized: "Documents")),
            PinnedFolder(id: PinnedFolder.recentsID, title: String(localized: "Recents")),
            PinnedFolder(id: "/Applications", title: String(localized: "Applications")),
        ]
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([PinnedFolder].self, from: data) {
            items = saved
        } else {
            items = Self.defaults
        }
    }

    func add(_ url: URL) {
        guard !items.contains(where: { $0.id == url.path }) else { return }
        items.append(PinnedFolder(id: url.path, title: FileManager.default.displayName(atPath: url.path)))
    }

    func resetToDefaults() { items = Self.defaults }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    // MARK: Opening

    /// Opens the folder in Finder. Recents is a saved search over files used in the last month.
    static func open(_ folder: PinnedFolder) {
        if let url = folder.url {
            NSWorkspace.shared.open(url)
            return
        }
        let directory = URL.applicationSupportDirectory.appendingPathComponent("Shiftio")
        let file = directory.appendingPathComponent("Recents.savedSearch")
        let query = "kMDItemLastUsedDate >= $time.today(-30) && kMDItemContentType != public.folder"
        let plist: [String: Any] = [
            "CompatibleVersion": 1,
            "RawQuery": query,
            "RawQueryDict": ["RawQuery": query, "SearchScopes": ["kMDQueryScopeComputer"], "UserFilesOnly": true],
            "SearchCriteria": ["FXScopeArrayOfPaths": ["kMDQueryScopeComputer"]],
        ]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: file)
            NSWorkspace.shared.open(file)
        } catch {
            NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()))
        }
    }

    /// What to show for a folder: its own icon, or that icon with the user's glyph printed on it.
    func icon(for folder: PinnedFolder, style: ItemStyle? = nil) -> NSImage? {
        if let icon = style?.icon { return FolderIcon.make(base: FolderIcon.baseIcon(for: folder), icon: icon) }
        return folder.url == nil ? nil : FolderIcon.baseIcon(for: folder)
    }
}
