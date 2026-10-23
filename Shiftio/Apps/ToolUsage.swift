import Foundation
import Observation

/// Remembers which tools (convert, compress, trim…) were used on files, for the Recent ring that opens first.
/// Kept in Application Support next to the app usage list.
@MainActor @Observable
final class ToolUsage {
    private struct Saved: Codable {
        var recent: [String]
        var counts: [String: Int]
    }

    static let shared = ToolUsage()

    private(set) var recentIDs: [String] = []
    private(set) var counts: [String: Int] = [:]
    private var saveTask: Task<Void, Never>?

    private let fileURL: URL

    init(file: URL = URL.applicationSupportDirectory.appendingPathComponent("Shiftio/tool-usage.json")) {
        fileURL = file
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            recentIDs = saved.recent
            counts = saved.counts
        }
    }

    func record(_ id: String) {
        recentIDs.removeAll { $0 == id }
        recentIDs.insert(id, at: 0)
        if recentIDs.count > 40 { recentIDs.removeLast(recentIDs.count - 40) }
        counts[id, default: 0] += 1
        scheduleSave()
    }

    /// Forgets the recent and frequent tools.
    func clear() {
        recentIDs = []
        counts = [:]
        scheduleSave()
    }

    /// The last tools used that fit the files being dragged (`fits` says which do).
    func recent(limit: Int, where fits: (String) -> Bool) -> [String] {
        Array(recentIDs.filter(fits).prefix(limit))
    }

    /// The tools used most (twice or more) that fit the files.
    func frequent(limit: Int, where fits: (String) -> Bool) -> [String] {
        Array(counts.filter { $0.value >= 2 }.sorted { $0.value > $1.value }.map(\.key).filter(fits).prefix(limit))
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let fileURL = fileURL
        saveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            let saved = Saved(recent: recentIDs, counts: counts)
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(saved).write(to: fileURL, options: .atomic)
        }
    }
}
