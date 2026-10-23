import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Writes a copy without EXIF/GPS/IPTC (images) or document info (PDF).
struct StripMetadataAction: FileAction {
    var id: String { "strip-metadata" }
    var title: String { String(localized: "Metadata") }
    var symbol: String? { "tag.slash" }
    var inputTypes: [UTType] { [.image, .pdf] }

    func run(_ urls: [URL], options: ActionOptions) async throws -> [URL] {
        try urls.map { url in
            let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
            let output = OutputNamer.url(for: url, ext: ext, suffix: "clean")
            if UTType.of(url)?.conforms(to: .pdf) == true {
                guard let document = PDFDocument(url: url) else { throw ShiftioError.unreadable(url) }
                document.documentAttributes = [:]
                guard document.write(to: output) else { throw ShiftioError.writeFailed(output) }
            } else {
                try stripImage(url, to: output)
            }
            return output
        }
    }

    private func stripImage(_ url: URL, to output: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source)
        else { throw ShiftioError.unreadable(url) }
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type, 1, nil)
        else { throw ShiftioError.writeFailed(output) }

        let remove: [CFString: Any] = [
            kCGImagePropertyExifDictionary: kCFNull!,
            kCGImagePropertyGPSDictionary: kCFNull!,
            kCGImagePropertyIPTCDictionary: kCFNull!,
            kCGImagePropertyTIFFDictionary: kCFNull!,
            kCGImageMetadataShouldExcludeXMP: true,
            kCGImageMetadataShouldExcludeGPS: true,
        ]
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(destination, source, remove as CFDictionary, &error) else {
            throw ShiftioError.writeFailed(output)
        }
    }
}
