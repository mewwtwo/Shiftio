import AppKit

/// Screenshots and screen recordings through the system's own `screencapture` tool, shown in Quick Look when done.
/// Nothing here runs until a tile's option is chosen, so opening the ring never asks for Screen Recording access.
final class ScreenCapture: @unchecked Sendable {
    static let shared = ScreenCapture()
    static let quickLookKey = "captureQuickLook"

    enum Shot: Sendable {
        case selection, window, screen

        var arguments: [String] {
            switch self {
            case .selection: ["-i"]
            case .window: ["-i", "-w"]
            case .screen: []
            }
        }
    }

    private let lock = NSLock()
    private var recorder: Process?
    private var recordingURL: URL?

    var isRecording: Bool {
        lock.withLock { recorder?.isRunning == true }
    }

    /// Where the system saves its own screenshots (the Screenshot app's setting), else the Desktop.
    private static var folder: URL {
        if let path = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    private static func newFile(_ kind: String, _ ext: String) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return folder.appendingPathComponent("\(kind) \(formatter.string(from: Date())).\(ext)")
    }

    /// Takes the picture (cancelling the selection saves nothing) and opens it in Quick Look.
    func screenshot(_ shot: Shot) async {
        let file = Self.newFile(String(localized: "Screenshot"), "png")
        try? await Task.sleep(for: .milliseconds(550))   // the ring is fading out; it must not be in the picture
        guard await Self.run(shot.arguments + [file.path]) else { return }
        Self.quickLook(file)
    }

    func startRecording() async {
        guard !isRecording else { return }
        try? await Task.sleep(for: .milliseconds(550))   // the ring is fading out; it must not be in the movie
        let file = Self.newFile(String(localized: "Screen Recording"), "mov")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-v", "-x", file.path]
        guard (try? process.run()) != nil else { return }
        lock.withLock {
            recorder = process
            recordingURL = file
        }
    }

    /// Ends the recording (the tool finishes the movie when interrupted) and opens it in Quick Look.
    func stopRecording() async {
        let (process, file) = lock.withLock { (recorder, recordingURL) }
        guard let process, let file, process.isRunning else { return }
        process.interrupt()
        await Task.detached { process.waitUntilExit() }.value
        lock.withLock { recorder = nil }
        Self.quickLook(file)
    }

    private static func run(_ arguments: [String]) async -> Bool {
        let file = arguments.last ?? ""
        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = arguments
            guard (try? process.run()) != nil else { return false }
            process.waitUntilExit()
            return FileManager.default.fileExists(atPath: file)
        }.value
    }

    private static func quickLook(_ file: URL) {
        guard FileManager.default.fileExists(atPath: file.path),
              UserDefaults.standard.object(forKey: quickLookKey) as? Bool ?? true else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        process.arguments = ["-p", file.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
