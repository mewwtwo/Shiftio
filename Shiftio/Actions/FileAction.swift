import Foundation
import UniformTypeIdentifiers

enum ActionKind: Sendable {
    case instant
    case editor
}

struct ActionOptions: Sendable {
    var jpegQuality: Double = 0.9
    var pdfDPI: Double = 144
    /// Target of the generic "Audio" sector.
    var audioFormat = AudioFormat.mp3
    var mp3Bitrate = 192
}

/// A single operation that can sit in a ring segment.
protocol FileAction: Sendable {
    var id: String { get }
    var title: String { get }
    var symbol: String? { get }
    var inputTypes: [UTType] { get }
    /// Output type, used to hide no-op conversions (JPG → JPG).
    var outputType: UTType? { get }
    var kind: ActionKind { get }
    /// Batch actions (merge, zip) only appear when at least this many files are dragged.
    var minimumFileCount: Int { get }
    /// Name shown in the ring; most actions use `title`, the generic Audio action shows the chosen format.
    func displayTitle(options: ActionOptions) -> String
    /// Toggles (Wi-Fi, Dark Mode…) report whether they are on; ordinary actions return nil.
    func state() -> Bool?
    /// Symbol for the current state, e.g. `wifi` vs `wifi.slash`.
    func displaySymbol(isOn: Bool?) -> String?
    func run(_ urls: [URL], options: ActionOptions) async throws -> [URL]
}

extension FileAction {
    var symbol: String? { nil }
    var outputType: UTType? { nil }
    var kind: ActionKind { .instant }
    var minimumFileCount: Int { 1 }
    func displayTitle(options: ActionOptions) -> String { title }
    func state() -> Bool? { nil }
    func displaySymbol(isOn: Bool?) -> String? { symbol }

    func accepts(_ url: URL) -> Bool {
        guard let type = UTType.of(url) else { return false }
        return accepts(type)
    }

    func accepts(_ type: UTType) -> Bool {
        if let outputType, type.conforms(to: outputType) { return false }
        return inputTypes.contains { type.conforms(to: $0) }
    }
}

extension UTType {
    static let srt = UTType(filenameExtension: "srt") ?? .plainText
    static let docx = UTType(filenameExtension: "docx") ?? .data

    static func of(_ url: URL) -> UTType? {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType { return type }
        return UTType(filenameExtension: url.pathExtension)
    }
}

enum ShiftioError: LocalizedError {
    case unreadable(URL)
    case writeFailed(URL)
    case emptyResult(String)
    case needsEditor
    case unavailable(String)
    case encoderMissing(String, String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let url): String(localized: "Can't read \(url.lastPathComponent)")
        case .writeFailed(let url): String(localized: "Can't write \(url.lastPathComponent)")
        case .emptyResult(let what): String(localized: "Nothing to export: \(what)")
        case .needsEditor: String(localized: "This action opens an editor")
        case .unavailable(let what): String(localized: "\(what) isn't available on this Mac")
        case .encoderMissing(let format, let install): String(localized: "The \(format) encoder isn't installed yet: \(install)")
        }
    }
}
