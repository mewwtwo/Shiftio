import Foundation

/// Builds output URLs next to the source file without overwriting anything.
enum OutputNamer {
    /// `Page 001.pdf` + `jpg` → `Page 001.jpg`, then `Page 001 2.jpg` on conflict.
    /// `suffix` is appended to the base name, e.g. page numbers: `Page 001 (p2).jpg`.
    static func url(for source: URL, ext: String, suffix: String? = nil,
                    directory: URL? = nil, fileManager: FileManager = .default) -> URL {
        var base = source.deletingPathExtension().lastPathComponent
        if let suffix { base += " \(suffix)" }
        return url(named: base, ext: ext, in: directory ?? source.deletingLastPathComponent(), fileManager: fileManager)
    }

    /// Free name for a new file in `dir`, e.g. `Merged.pdf`, `Merged 2.pdf`.
    static func url(named base: String, ext: String, in dir: URL, fileManager: FileManager = .default) -> URL {
        var candidate = dir.appendingPathComponent(base).appendingPathExtension(ext)
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) \(counter)").appendingPathExtension(ext)
            counter += 1
        }
        return candidate
    }

    /// AVFoundation writes next to the output under a `.sb-…` name and renames it when it is done. A failed, cancelled
    /// or interrupted run can leave that file behind; the user never asked for it.
    static func removePartials(of output: URL, fileManager: FileManager = .default) {
        let directory = output.deletingLastPathComponent()
        let prefix = output.lastPathComponent + ".sb-"
        for name in (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasPrefix(prefix) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
