import AVFoundation
import AppKit
import CoreImage

/// A rectangle of the picture to hide. `rect` is in fractions of the picture, measured from the top left.
struct VideoBlur: Identifiable, Equatable {
    let id = UUID()
    var rect: CGRect
    /// Big blocks instead of a soft blur, which cannot be undone by sharpening.
    var pixelates: Bool
}

enum WatermarkCorner: String, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight, center
    /// Repeated all over the picture, turned a little, like a stock-photo mark.
    case tiled
    var id: String { rawValue }

    var title: String {
        switch self {
        case .topLeft: String(localized: "Top left")
        case .topRight: String(localized: "Top right")
        case .bottomLeft: String(localized: "Bottom left")
        case .bottomRight: String(localized: "Bottom right")
        case .center: String(localized: "Centre")
        case .tiled: String(localized: "Whole frame")
        }
    }

    /// Where an image of `imageSize` lands in a picture of `frame`, from the top left. `fraction` is its width as a share of the picture's.
    func rect(imageSize: CGSize, in frame: CGSize, fraction: Double) -> CGRect {
        let width = frame.width * fraction
        let height = imageSize.width > 0 ? width * imageSize.height / imageSize.width : 0
        let margin = frame.width * 0.03
        let origin: CGPoint = switch self {
        case .topLeft: CGPoint(x: margin, y: margin)
        case .topRight: CGPoint(x: frame.width - width - margin, y: margin)
        case .bottomLeft: CGPoint(x: margin, y: frame.height - height - margin)
        case .bottomRight: CGPoint(x: frame.width - width - margin, y: frame.height - height - margin)
        case .center: CGPoint(x: (frame.width - width) / 2, y: (frame.height - height) / 2)
        case .tiled: .zero
        }
        return CGRect(origin: origin, size: CGSize(width: width, height: height))
    }
}

/// The repeated placement of a tiled watermark. Cells are laid in rows, every other row shifted half a step, over an area
/// big enough that the whole picture is still covered after the grid is turned by `angle` about the picture's centre.
enum WatermarkTiling {
    /// Radians, clockwise on screen.
    static let angle = -Double.pi / 7

    static func cells(imageSize: CGSize, in frame: CGSize, fraction: Double) -> [CGRect] {
        guard imageSize.width > 0, imageSize.height > 0 else { return [] }
        let width = frame.width * fraction
        let height = width * imageSize.height / imageSize.width
        let stepX = width * 1.8, stepY = max(height * 3, width * 0.5)
        let reach = hypot(frame.width, frame.height)
        let left = (frame.width - reach) / 2, top = (frame.height - reach) / 2
        var cells: [CGRect] = []
        var row = 0
        var y = top
        while y < top + reach {
            var x = left + (row.isMultiple(of: 2) ? 0 : stepX / 2)
            while x < left + reach {
                cells.append(CGRect(x: x, y: y, width: width, height: height))
                x += stepX
            }
            y += stepY
            row += 1
        }
        return cells
    }
}

enum WatermarkSize: Double, CaseIterable, Identifiable {
    case small = 0.12, medium = 0.2, large = 0.32
    var id: Double { rawValue }
    var title: String {
        switch self {
        case .small: String(localized: "Small")
        case .medium: String(localized: "Medium")
        case .large: String(localized: "Large")
        }
    }
}

/// A logo or a line of text laid over the picture.
struct Watermark {
    var image: CGImage
    var corner = WatermarkCorner.bottomRight
    var size = WatermarkSize.medium
    var opacity = 0.85
}

struct SubtitleCue: Equatable {
    let start: Double
    let end: Double
    let text: String
}

enum SubtitleMode: String, CaseIterable, Identifiable {
    case off, burnIn, file
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: String(localized: "Off")
        case .burnIn: String(localized: "On the Video")
        case .file: String(localized: "SRT File")
        }
    }
}

/// Text as a picture, for watermarks and burned-in subtitles.
enum TextImage {
    @MainActor
    static func render(_ text: String, size: CGFloat, maxWidth: CGFloat = 4000, boxed: Bool) -> CGImage? {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .bold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: style,
        ]
        if !boxed {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
            shadow.shadowBlurRadius = size * 0.08
            shadow.shadowOffset = NSSize(width: 0, height: -size * 0.04)
            attributes[.shadow] = shadow
        }
        let string = NSAttributedString(string: text, attributes: attributes)
        let padding = boxed ? size * 0.45 : size * 0.2
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let bounds = string.boundingRect(with: NSSize(width: max(size, maxWidth - padding * 2), height: .greatestFiniteMagnitude), options: options)
        let imageSize = NSSize(width: ceil(bounds.width + padding * 2), height: ceil(bounds.height + padding * 2))
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }
        let image = NSImage(size: imageSize, flipped: false) { rect in
            if boxed {
                NSColor.black.withAlphaComponent(0.6).setFill()
                NSBezierPath(roundedRect: rect, xRadius: size * 0.35, yRadius: size * 0.35).fill()
            }
            string.draw(with: NSRect(x: padding, y: padding, width: ceil(bounds.width), height: ceil(bounds.height)), options: options)
            return true
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

/// Draws blur regions, the watermark and subtitles onto each frame. Built once on the main actor (text has to be drawn
/// there); after that it only reads, so the video pipeline can call it from any thread.
final class OverlayRenderer: @unchecked Sendable {
    private struct Cue {
        let start: Double
        let end: Double
        let image: CIImage
    }

    private let blurs: [VideoBlur]
    private let watermark: (image: CIImage, corner: WatermarkCorner, fraction: Double)?
    private let cues: [Cue]

    private init(blurs: [VideoBlur], watermark: (image: CIImage, corner: WatermarkCorner, fraction: Double)?, cues: [Cue]) {
        self.blurs = blurs
        self.watermark = watermark
        self.cues = cues
    }

    /// nil when the edit adds nothing to the picture. `size` is the picture the overlays are laid on.
    @MainActor
    static func make(for edit: VideoEdit, size: CGSize) -> OverlayRenderer? {
        guard edit.hasOverlays else { return nil }
        let cues = edit.subtitles.compactMap { cue -> Cue? in
            guard let image = TextImage.render(cue.text, size: size.height * 0.045, maxWidth: size.width * 0.88, boxed: true) else { return nil }
            return Cue(start: cue.start, end: cue.end, image: CIImage(cgImage: image))
        }
        let mark = edit.watermark.map { mark in
            let faded = CIImage(cgImage: mark.image)
                .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: mark.opacity)])
            let image = mark.corner == .tiled ? tiledLayer(faded, size: size, fraction: mark.size.rawValue) : faded
            return (image: image, corner: mark.corner, fraction: mark.size.rawValue)
        }
        return OverlayRenderer(blurs: edit.blurs, watermark: mark, cues: cues)
    }

    /// All the copies in one picture the size of the frame, drawn once so each video frame only has to lay it on.
    @MainActor
    private static func tiledLayer(_ mark: CIImage, size: CGSize, fraction: Double) -> CIImage {
        let frame = CGRect(origin: .zero, size: size)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        var layer = CIImage(color: .clear).cropped(to: frame)
        for cell in WatermarkTiling.cells(imageSize: mark.extent.size, in: size, fraction: fraction) {
            let scale = cell.width / mark.extent.width
            // Coordinates here run upwards, so the turn and the row positions are mirrored from the screen's.
            let turn = CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: -WatermarkTiling.angle)
                .translatedBy(x: -center.x, y: -center.y)
            let place = CGAffineTransform(scaleX: scale, y: scale)
                .concatenating(CGAffineTransform(translationX: cell.minX, y: size.height - cell.maxY))
                .concatenating(turn)
            let copy = mark.transformed(by: place)
            guard copy.extent.intersects(frame) else { continue }
            layer = copy.composited(over: layer)
        }
        let context = CIContext()
        guard let picture = context.createCGImage(layer, from: frame) else { return layer }
        return CIImage(cgImage: picture)
    }

    func render(_ source: CIImage, at time: Double) -> CIImage {
        let extent = source.extent
        let width = extent.width, height = extent.height
        var result = source

        for blur in blurs {
            let region = CGRect(x: extent.minX + blur.rect.minX * width, y: extent.minY + (1 - blur.rect.maxY) * height,
                                width: blur.rect.width * width, height: blur.rect.height * height).integral
            let strength = max(6, min(width, height) / 45)
            let changed: CIImage = blur.pixelates
                ? source.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: strength * 1.6, kCIInputCenterKey: CIVector(x: extent.minX, y: extent.minY)])
                : source.clampedToExtent().applyingGaussianBlur(sigma: strength)
            result = changed.cropped(to: region).composited(over: result)
        }

        func place(_ image: CIImage, in rect: CGRect) -> CIImage {
            let scale = rect.width / image.extent.width
            return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)
                .concatenating(CGAffineTransform(translationX: extent.minX + rect.minX, y: extent.minY + height - rect.maxY)))
        }

        if let watermark, watermark.corner == .tiled {
            result = watermark.image.transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY)).composited(over: result)
        } else if let watermark {
            let rect = watermark.corner.rect(imageSize: watermark.image.extent.size, in: extent.size, fraction: watermark.fraction)
            result = place(watermark.image, in: rect).composited(over: result)
        }
        if let cue = cues.first(where: { time >= $0.start && time < $0.end }) {
            let size = cue.image.extent.size
            let rect = CGRect(x: (width - size.width) / 2, y: height - size.height - height * 0.06, width: size.width, height: size.height)
            result = place(cue.image, in: rect).composited(over: result)
        }
        return result.cropped(to: extent)
    }

    /// A render of `asset` that applies the overlays frame by frame.
    @MainActor
    func composition(for asset: AVAsset) async throws -> AVVideoComposition {
        try await AVVideoComposition.videoComposition(with: asset, applyingCIFiltersWithHandler: handler())
    }

    /// Made outside the main actor, because the video pipeline calls it from its own threads.
    private nonisolated func handler() -> @Sendable (AVAsynchronousCIImageFilteringRequest) -> Void {
        { [self] request in
            request.finish(with: render(request.sourceImage, at: request.compositionTime.seconds), context: nil)
        }
    }
}
