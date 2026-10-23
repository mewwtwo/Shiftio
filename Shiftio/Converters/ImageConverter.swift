import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum ImageFormat: String, CaseIterable, Sendable {
    case jpg, png, heic, tiff, gif, bmp

    var type: UTType {
        switch self {
        case .jpg: .jpeg
        case .png: .png
        case .heic: .heic
        case .tiff: .tiff
        case .gif: .gif
        case .bmp: .bmp
        }
    }

    var supportsAlpha: Bool { self != .jpg && self != .bmp }
}

/// Converts images (and PDF pages) to raster formats via ImageIO.
struct ConvertToImageAction: FileAction {
    let format: ImageFormat

    var id: String { format.rawValue }
    var title: String { format.rawValue.uppercased() }
    var inputTypes: [UTType] { [.image, .pdf] }
    var outputType: UTType? { format.type }

    func run(_ urls: [URL], options: ActionOptions) async throws -> [URL] {
        var outputs: [URL] = []
        for url in urls {
            if UTType.of(url)?.conforms(to: .pdf) == true {
                outputs += try ImageConverter.convertPDF(url, to: format, options: options)
            } else {
                outputs.append(try ImageConverter.convertImage(url, to: format, options: options))
            }
        }
        return outputs
    }
}

enum ImageConverter {
    static func convertImage(_ url: URL, to format: ImageFormat, options: ActionOptions) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw ShiftioError.unreadable(url) }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let output = OutputNamer.url(for: url, ext: format.rawValue)
        try write(image, to: output, format: format, properties: properties, options: options)
        return output
    }

    static func convertPDF(_ url: URL, to format: ImageFormat, options: ActionOptions) throws -> [URL] {
        guard let document = PDFDocument(url: url) else { throw ShiftioError.unreadable(url) }
        guard document.pageCount > 0 else { throw ShiftioError.emptyResult(url.lastPathComponent) }

        var outputs: [URL] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let image = render(page, dpi: options.pdfDPI) else { continue }
            let suffix = document.pageCount > 1 ? "(p\(index + 1))" : nil
            let output = OutputNamer.url(for: url, ext: format.rawValue, suffix: suffix)
            try write(image, to: output, format: format, properties: nil, options: options)
            outputs.append(output)
        }
        return outputs
    }

    static func render(_ page: PDFPage, dpi: Double) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let scale = dpi / 72
        let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    static func write(_ image: CGImage, to url: URL, format: ImageFormat,
                      properties: [CFString: Any]?, options: ActionOptions) throws {
        let image = format.supportsAlpha ? image : flattened(image) ?? image
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, format.type.identifier as CFString, 1, nil)
        else { throw ShiftioError.writeFailed(url) }

        var props = properties ?? [:]
        props[kCGImageDestinationLossyCompressionQuality] = options.jpegQuality
        CGImageDestinationAddImage(destination, image, props as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ShiftioError.writeFailed(url) }
    }

    /// Draws onto white so transparent areas don't turn black in JPG/BMP.
    static func flattened(_ image: CGImage) -> CGImage? {
        guard image.alphaInfo != .none, image.alphaInfo != .noneSkipLast, image.alphaInfo != .noneSkipFirst else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(.white)
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage()
    }
}
