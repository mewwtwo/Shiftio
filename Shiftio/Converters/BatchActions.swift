import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// PDFs and images → one `Merged.pdf`, in drag order.
struct MergePDFAction: FileAction {
    var id: String { "merge-pdf" }
    var title: String { String(localized: "Merge PDF") }
    var symbol: String? { "doc.on.doc" }
    var inputTypes: [UTType] { [.pdf, .image] }
    var minimumFileCount: Int { 2 }

    func run(_ urls: [URL], options: ActionOptions) async throws -> [URL] {
        guard let first = urls.first else { return [] }
        let merged = PDFDocument()
        for url in urls {
            if UTType.of(url)?.conforms(to: .pdf) == true {
                guard let document = PDFDocument(url: url) else { throw ShiftioError.unreadable(url) }
                for index in 0..<document.pageCount {
                    if let page = document.page(at: index) { merged.insert(page, at: merged.pageCount) }
                }
            } else {
                guard let image = NSImage(contentsOf: url), let page = PDFPage(image: image) else {
                    throw ShiftioError.unreadable(url)
                }
                merged.insert(page, at: merged.pageCount)
            }
        }
        let output = OutputNamer.url(named: "Merged", ext: "pdf", in: first.deletingLastPathComponent())
        guard merged.write(to: output) else { throw ShiftioError.writeFailed(output) }
        return [output]
    }
}

/// Any files → `Archive.zip` next to the first one.
struct ZipAction: FileAction {
    var id: String { "zip" }
    var title: String { "ZIP" }
    var symbol: String? { "archivebox" }
    var inputTypes: [UTType] { [.item] }
    var minimumFileCount: Int { 2 }

    func run(_ urls: [URL], options: ActionOptions) async throws -> [URL] {
        guard let first = urls.first else { return [] }
        let dir = first.deletingLastPathComponent()
        let output = OutputNamer.url(named: "Archive", ext: "zip", in: dir)
        // Files in the same folder keep short names inside the archive.
        let names = urls.map { $0.deletingLastPathComponent() == dir ? $0.lastPathComponent : $0.path }
        try Shell.run("/usr/bin/zip", ["-r", "-q", "-X", output.path] + names, in: dir)
        return [output]
    }
}

enum Shell {
    /// Runs a tool without blocking a thread; long encodes must not stall the cooperative pool.
    static func runAsync(_ executable: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            nonisolated(unsafe) let errors = Pipe()
            process.standardError = errors
            process.terminationHandler = { finished in
                if finished.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let name = URL(fileURLWithPath: executable).lastPathComponent
                    continuation.resume(throwing: Failure(message: String(localized: "\(name) failed: \(message.trimmingCharacters(in: .whitespacesAndNewlines))")))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func run(_ executable: String, _ arguments: [String], in directory: URL? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw Failure(message: String(localized: "\(URL(fileURLWithPath: executable).lastPathComponent) failed: \(message)"))
        }
    }
}
