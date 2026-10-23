import AppKit
import AVFoundation
import Foundation
import ImageIO
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Squeezes images, PDFs, audio and video. Opens a window where the degree of compression and the details are
/// chosen for each kind of file, so a drop of mixed files gets one section per kind.
struct CompressAction: EditorAction {
    var id: String { "compress" }
    var title: String { String(localized: "Compress") }
    var symbol: String? { "arrow.down.right.and.arrow.up.left" }
    var inputTypes: [UTType] { [.image, .pdf, .audiovisualContent] }
    var handlesBatch: Bool { true }

    @MainActor
    func present(_ url: URL, tint: Color, complete: @escaping @MainActor (Result<[URL], Error>) -> Void) {
        presentBatch([url], tint: tint) { _, result in complete(result) }
    }

    @MainActor
    func presentBatch(_ urls: [URL], tint: Color, complete: @escaping @MainActor (_ sources: [URL], Result<[URL], Error>) -> Void) {
        let model = CompressModel(files: urls)
        guard !model.kinds.isEmpty else {
            complete(urls, .failure(ShiftioError.unreadable(urls.first ?? URL(fileURLWithPath: "/"))))
            return
        }
        let height: CGFloat = switch model.kinds.count == 1 ? model.kinds[0] : nil {
        case .video?: 710
        case .image?, .pdf?: 540
        case .audio?: 470
        case nil: 800
        }
        // Tall enough to show every control without scrolling, but never taller than the screen.
        let room = (NSScreen.main?.visibleFrame.height ?? 900) - 40
        EditorWindowController.shared.present(size: CGSize(width: 520, height: min(height, room))) { close in
            CompressView(model: model, tint: tint, onClose: close, onFinish: complete)
        }
    }
}

enum Compressor {
    /// The compressed file next to the original; `progress` runs from 0 to 1 and only moves for audio and video.
    @concurrent
    static func compress(_ url: URL, settings: CompressSettings, transcoder: Transcoder,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        switch CompressKind(url: url) {
        case .image?:
            let result = try await imageData(url, settings: settings.image)
            let output = OutputNamer.url(for: url, ext: result.ext, suffix: "compressed")
            try result.data.write(to: output)
            return output
        case .pdf?:
            return try compressPDF(url, settings: settings.pdf)
        case .audio?:
            let output = OutputNamer.url(for: url, ext: "m4a", suffix: "compressed")
            let audio = settings.audio
            try await transcoder.run(url, to: output, hasVideo: false, audioKbps: audio.kbps, plans: { _, _, _ in
                (nil, Transcoder.AudioPlan(kbps: audio.kbps, sampleRate: audio.sampleRate, mono: audio.mono))
            }, progress: progress)
            return output
        case .video?:
            let output = OutputNamer.url(for: url, ext: "mp4", suffix: "compressed")
            let video = settings.video
            try await transcoder.run(url, to: output, hasVideo: true, audioKbps: video.audioKbps, plans: { natural, fps, duration in
                let size = video.outputSize(of: natural)
                let outFPS = video.outputFPS(source: fps)
                return (Transcoder.VideoPlan(size: size, codec: video.codec,
                                             bitrate: video.videoBitrate(size: size, fps: outFPS, duration: duration),
                                             fps: outFPS, sourceFPS: fps),
                        Transcoder.AudioPlan(kbps: video.audioKbps, sampleRate: 0, mono: false))
            }, progress: progress)
            return output
        case nil:
            throw ShiftioError.unreadable(url)
        }
    }

    // MARK: Images

    /// The encoded picture; also what the window encodes to show the size a setting would give.
    @concurrent
    static func imageData(_ url: URL, settings: ImageCompress) async throws -> (data: Data, ext: String) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              var properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw ShiftioError.unreadable(url) }

        let isHEIC = UTType.of(url)?.conforms(to: .heic) == true
        // Lossless formats become JPG when left on Same; lossy ones keep their format.
        let format: ImageFormat = switch settings.target {
        case .jpg: .jpg
        case .heic: .heic
        case .auto: isHEIC ? .heic : .jpg
        }

        // The thumbnail call applies the orientation and the scale in one go, so the stored orientation resets to 1.
        let longest = max(1, Int((Double(max(width, height)) * settings.scale).rounded()))
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longest,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary) else { throw ShiftioError.unreadable(url) }

        if settings.keepMetadata {
            properties[kCGImagePropertyOrientation] = 1
            properties[kCGImagePropertyPixelWidth] = nil
            properties[kCGImagePropertyPixelHeight] = nil
            if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                properties[kCGImagePropertyTIFFDictionary] = tiff
            }
        } else {
            properties = [:]
        }
        properties[kCGImageDestinationLossyCompressionQuality] = settings.quality

        let flat = format.supportsAlpha ? image : ImageConverter.flattened(image) ?? image
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, format.type.identifier as CFString, 1, nil)
        else { throw ShiftioError.writeFailed(url) }
        CGImageDestinationAddImage(destination, flat, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ShiftioError.writeFailed(url) }
        return (data as Data, format.rawValue)
    }

    // MARK: PDF

    private static func compressPDF(_ url: URL, settings: PDFCompress) throws -> URL {
        guard let document = PDFDocument(url: url) else { throw ShiftioError.unreadable(url) }
        let output = OutputNamer.url(for: url, ext: "pdf", suffix: "compressed")

        switch settings.mode {
        case .optimize:
            var options: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true]
            if settings.screenImages { options[.optimizeImagesForScreenOption] = true }
            guard document.write(to: output, withOptions: options) else { throw ShiftioError.writeFailed(output) }
        case .flatten:
            guard document.pageCount > 0 else { throw ShiftioError.emptyResult(url.lastPathComponent) }
            let flattened = PDFDocument()
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index), var image = ImageConverter.render(page, dpi: settings.dpi) else { continue }
                if settings.grayscale { image = gray(image) ?? image }
                let points = NSSize(width: Double(image.width) * 72 / settings.dpi, height: Double(image.height) * 72 / settings.dpi)
                let picture = NSImage(cgImage: image, size: points)
                guard let flatPage = PDFPage(image: picture, options: [.compressionQuality: settings.quality]) else { continue }
                flattened.insert(flatPage, at: flattened.pageCount)
            }
            guard flattened.pageCount > 0, flattened.write(to: output) else { throw ShiftioError.writeFailed(output) }
        }
        return output
    }

    private static func gray(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}
