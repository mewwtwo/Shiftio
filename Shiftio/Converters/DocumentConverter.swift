import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers
import Vision

enum DocumentFormat: String, CaseIterable, Sendable {
    case docx, rtf, html, txt

    var type: UTType {
        switch self {
        case .docx: .docx
        case .rtf: .rtf
        case .html: .html
        case .txt: .plainText
        }
    }

    var documentType: NSAttributedString.DocumentType {
        switch self {
        case .docx: .officeOpenXML
        case .rtf: .rtf
        case .html: .html
        case .txt: .plain
        }
    }
}

/// Text documents and PDFs ↔ DOCX/RTF/HTML/TXT. Images → TXT goes through OCR.
struct ConvertToDocumentAction: FileAction {
    let format: DocumentFormat

    var id: String { format.rawValue }
    var title: String { format.rawValue.uppercased() }
    var symbol: String? { format == .txt ? "text.viewfinder" : nil }
    var outputType: UTType? { format.type }
    var inputTypes: [UTType] {
        let documents: [UTType] = [.pdf, .rtf, .html, .plainText, .docx, .rtfd]
        return format == .txt ? documents + [.image] : documents
    }

    func run(_ urls: [URL], options: ActionOptions) async throws -> [URL] {
        var outputs: [URL] = []
        for url in urls {
            let output = OutputNamer.url(for: url, ext: format.rawValue)
            if UTType.of(url)?.conforms(to: .image) == true {
                let text = try await DocumentConverter.recognizeText(in: url)
                try text.write(to: output, atomically: true, encoding: .utf8)
            } else {
                try await DocumentConverter.convert(url, to: output, format: format)
            }
            outputs.append(output)
        }
        return outputs
    }
}

enum DocumentConverter {
    @MainActor
    static func convert(_ url: URL, to output: URL, format: DocumentFormat) throws {
        try write(load(url), to: output, format: format)
    }

    /// HTML import uses WebKit internally, so loading stays on the main actor.
    @MainActor
    static func load(_ url: URL) throws -> NSAttributedString {
        if UTType.of(url)?.conforms(to: .pdf) == true {
            guard let document = PDFDocument(url: url) else { throw ShiftioError.unreadable(url) }
            let result = NSMutableAttributedString()
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index)?.attributedString else { continue }
                if result.length > 0 { result.append(NSAttributedString(string: "\n\n")) }
                result.append(page)
            }
            guard result.length > 0 else { throw ShiftioError.emptyResult(String(localized: "no text layer in \(url.lastPathComponent)")) }
            return result
        }
        do {
            return try NSAttributedString(url: url, options: [:], documentAttributes: nil)
        } catch {
            throw ShiftioError.unreadable(url)
        }
    }

    static func write(_ text: NSAttributedString, to url: URL, format: DocumentFormat) throws {
        if format == .txt {
            try text.string.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        let data = try text.data(from: NSRange(location: 0, length: text.length),
                                 documentAttributes: [.documentType: format.documentType])
        try data.write(to: url, options: .atomic)
    }

    static func recognizeText(in url: URL) async throws -> String {
        var request = RecognizeTextRequest()
        request.automaticallyDetectsLanguage = true
        let observations = try await request.perform(on: url)
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        guard !lines.isEmpty else { throw ShiftioError.emptyResult(String(localized: "no text found in \(url.lastPathComponent)")) }
        return lines.joined(separator: "\n")
    }
}
