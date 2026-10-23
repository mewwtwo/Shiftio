import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// Images → one PDF per image (multi-file merge comes later).
struct ImagesToPDFAction: FileAction {
    var id: String { "pdf" }
    var title: String { "PDF" }
    var inputTypes: [UTType] { [.image] }
    var outputType: UTType? { .pdf }

    func run(_ urls: [URL], options: ActionOptions) async throws -> [URL] {
        try urls.map { url in
            guard let image = NSImage(contentsOf: url), let page = PDFPage(image: image) else {
                throw ShiftioError.unreadable(url)
            }
            let document = PDFDocument()
            document.insert(page, at: 0)
            let output = OutputNamer.url(for: url, ext: "pdf")
            guard document.write(to: output) else { throw ShiftioError.writeFailed(output) }
            return output
        }
    }
}
