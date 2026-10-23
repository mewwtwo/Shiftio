import AppKit

/// Every SF Symbol on this Mac with its search keywords, read from the system's own data (the same
/// names and keywords the SF Symbols app searches). Searching is by name and keyword, best matches first.
enum SymbolCatalog {
    struct Entry: Hashable {
        let name: String
        let keywords: [String]
    }

    private static let resources = "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/"

    static let all: [Entry] = {
        let keywords = (FileManager.default.contents(atPath: resources + "symbol_search.plist"))
            .flatMap { (try? PropertyListSerialization.propertyList(from: $0, format: nil)) as? [String: [String]] } ?? [:]
        // The full list in the SF Symbols app's order; the search table alone leaves out some plain names (like "wifi").
        var names = (FileManager.default.contents(atPath: resources + "symbol_order.plist"))
            .flatMap { (try? PropertyListSerialization.propertyList(from: $0, format: nil)) as? [String] } ?? []
        let known = Set(names)
        names += keywords.keys.filter { !known.contains($0) }.sorted()
        return names.map { Entry(name: $0, keywords: keywords[$0] ?? []) }
    }()

    /// Results for a search box. Several words must all match; an empty query returns the popular start of the list.
    static func search(_ query: String, limit: Int = 150) -> [String] {
        let words = query.lowercased().split(whereSeparator: { $0 == " " || $0 == "." }).map(String.init)
        guard !words.isEmpty else { return Array(all.prefix(limit).map(\.name)) }

        var scored: [(name: String, score: Int)] = []
        for entry in all {
            var total = 0
            for word in words {
                guard let score = score(word, in: entry) else { total = -1; break }
                total += score
            }
            if total >= 0 { scored.append((entry.name, total)) }
        }
        // Lower is better; ties keep the SF Symbols order, and shorter names come first.
        return scored.enumerated()
            .sorted { ($0.element.score, $0.element.name.count, $0.offset) < ($1.element.score, $1.element.name.count, $1.offset) }
            .prefix(limit).map(\.element.name)
    }

    private static func score(_ word: String, in entry: Entry) -> Int? {
        let name = entry.name.lowercased()
        let parts = name.split(separator: ".").map(String.init)
        if name == word { return 0 }
        if parts.contains(word) { return 1 }
        if name.hasPrefix(word) { return 2 }
        if parts.contains(where: { $0.hasPrefix(word) }) { return 3 }
        if entry.keywords.contains(where: { $0.lowercased() == word }) { return 4 }
        if entry.keywords.contains(where: { $0.lowercased().hasPrefix(word) }) { return 5 }
        if name.contains(word) { return 6 }
        if entry.keywords.contains(where: { $0.lowercased().contains(word) }) { return 7 }
        return nil
    }

    /// Only symbols this version of macOS can actually draw.
    static func isAvailable(_ name: String) -> Bool {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }
}
