import CryptoKit
import Foundation
import Observation

/// Tools that aren't part of the app (the MP3 encoder) are downloaded once, at first launch, into
/// ~/Library/Application Support/Shiftio/Components, so the app itself stays small and needs no installer.
@MainActor @Observable
final class ComponentInstaller {
    enum State: Equatable {
        case checking, installed, missing
        case installing(String)
        case failed(String)
    }

    private(set) var mp3 = State.checking

    /// `-ShiftioComponentsDir <path>` redirects the install folder (used by tests).
    nonisolated static var directory: URL {
        if let override = UserDefaults.standard.string(forKey: "ShiftioComponentsDir") { return URL(fileURLWithPath: override) }
        return URL.applicationSupportDirectory.appendingPathComponent("Shiftio/Components")
    }

    var isBusy: Bool {
        if case .installing = mp3 { return true }
        return false
    }

    func refresh() {
        guard !isBusy else { return }
        mp3 = MP3Encoder.locate() == nil ? .missing : .installed
    }

    /// Downloads whatever is missing. Safe to call repeatedly.
    func installMissing() async {
        refresh()
        if mp3 == .missing { await installMP3() }
    }

    func installMP3() async {
        guard !isBusy else { return }
        mp3 = .installing(String(localized: "Looking up the encoder…"))
        do {
            try await Self.downloadLame { [weak self] text in
                Task { @MainActor in self?.mp3 = .installing(text) }
            }
            mp3 = MP3Encoder.locate() == nil ? .failed(String(localized: "The encoder didn't start.")) : .installed
        } catch {
            mp3 = .failed(error.localizedDescription)
        }
    }

    // MARK: Download

    private struct Bottle {
        let url: URL
        let sha256: String
    }

    private struct InstallError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// LAME comes from Homebrew's public prebuilt packages, with the one library it needs (mpg123).
    nonisolated static func downloadLame(report: @escaping @Sendable (String) -> Void) async throws {
        let fileManager = FileManager.default
        let work = fileManager.temporaryDirectory.appendingPathComponent("shiftio-install-\(UUID().uuidString)")
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: work) }

        let lame = try await bottle("lame")
        let mpg123 = try await bottle("mpg123")
        report(String(localized: "Downloading the MP3 encoder (1 of 2)…"))
        let lameArchive = try await fetch(lame, into: work)
        report(String(localized: "Downloading the MP3 encoder (2 of 2)…"))
        let mpgArchive = try await fetch(mpg123, into: work)

        report(String(localized: "Installing…"))
        let extracted = work.appendingPathComponent("extracted")
        try fileManager.createDirectory(at: extracted, withIntermediateDirectories: true)
        try await Shell.runAsync("/usr/bin/tar", ["-xzf", lameArchive.path, "-C", extracted.path])
        try await Shell.runAsync("/usr/bin/tar", ["-xzf", mpgArchive.path, "-C", extracted.path])

        guard let lameBinary = find("lame", inFolder: "bin", under: extracted),
              let library = find("libmpg123.0.dylib", inFolder: "lib", under: extracted)
        else { throw InstallError(message: String(localized: "The downloaded package didn't contain the encoder.")) }

        let target = directory.appendingPathComponent("lame")
        try? fileManager.removeItem(at: target)
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        let installedLame = target.appendingPathComponent("lame")
        let installedLibrary = target.appendingPathComponent("libmpg123.0.dylib")
        try fileManager.copyItem(at: lameBinary, to: installedLame)
        try fileManager.copyItem(at: library, to: installedLibrary)

        // Package files are read-only; make them ours to edit and run.
        for file in [installedLibrary, installedLame] {
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        // Homebrew packages point at @@HOMEBREW_PREFIX@@; make lame look next to itself instead.
        try patch(installedLame, replacing: "@@HOMEBREW_PREFIX@@/opt/mpg123/lib/libmpg123.0.dylib",
                  with: "@loader_path/libmpg123.0.dylib")
        for file in [installedLibrary, installedLame] {
            // Editing a signed binary invalidates its signature, and Apple Silicon refuses unsigned code.
            try await Shell.runAsync("/usr/bin/codesign", ["--force", "--sign", "-", file.path])
        }
        try await Shell.runAsync(installedLame.path, ["--version"])
    }

    private nonisolated static func bottle(_ formula: String) async throws -> Bottle {
        let api = URL(string: "https://formulae.brew.sh/api/formula/\(formula).json")!
        let (data, _) = try await URLSession.shared.data(from: api)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stable = (root["bottle"] as? [String: Any])?["stable"] as? [String: Any],
              let files = stable["files"] as? [String: [String: Any]]
        else { throw InstallError(message: String(localized: "Couldn't read the package list for \(formula).")) }

        for tag in platformTags() {
            if let entry = files[tag], let url = (entry["url"] as? String).flatMap(URL.init(string:)),
               let sha = entry["sha256"] as? String {
                return Bottle(url: url, sha256: sha)
            }
        }
        throw InstallError(message: String(localized: "No MP3 encoder is available for this version of macOS."))
    }

    /// Package flavours for this Mac, newest first: only versions of macOS up to the current one can run.
    nonisolated static func platformTags() -> [String] {
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let names: [(Int, String)] = [(27, "golden_gate"), (26, "tahoe"), (15, "sequoia"), (14, "sonoma"),
                                      (13, "ventura"), (12, "monterey"), (11, "big_sur")]
        return names.filter { $0.0 <= major }.map { "arm64_" + $0.1 }
    }

    private nonisolated static func fetch(_ bottle: Bottle, into folder: URL) async throws -> URL {
        var request = URLRequest(url: bottle.url)
        request.setValue("Bearer QQ==", forHTTPHeaderField: "Authorization")   // Homebrew's anonymous read token
        let (downloaded, response) = try await URLSession.shared.download(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw InstallError(message: String(localized: "The download failed. Check your internet connection and try again."))
        }
        let data = try Data(contentsOf: downloaded, options: .mappedIfSafe)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == bottle.sha256 else { throw InstallError(message: String(localized: "The download was corrupted (checksum mismatch).")) }
        let destination = folder.appendingPathComponent(UUID().uuidString + ".tar.gz")
        try FileManager.default.moveItem(at: downloaded, to: destination)
        return destination
    }

    private nonisolated static func find(_ name: String, inFolder folder: String, under root: URL) -> URL? {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == name, url.deletingLastPathComponent().lastPathComponent == folder { return url }
        }
        return nil
    }

    /// Overwrites a string inside a binary with a shorter one, NUL-padded to the same length.
    private nonisolated static func patch(_ file: URL, replacing old: String, with new: String) throws {
        var data = try Data(contentsOf: file)
        let oldBytes = Data(old.utf8)
        var replaced = 0
        var searchStart = data.startIndex
        while let range = data.range(of: oldBytes, in: searchStart..<data.endIndex) {
            var replacement = Data(new.utf8)
            replacement.append(Data(count: oldBytes.count - replacement.count))
            data.replaceSubrange(range, with: replacement)
            searchStart = range.upperBound
            replaced += 1
        }
        guard replaced > 0 else { throw InstallError(message: String(localized: "The encoder package has an unexpected layout.")) }
        try data.write(to: file)
    }
}
