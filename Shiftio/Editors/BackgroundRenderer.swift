import AppKit
import CoreGraphics

enum BackgroundFill {
    case gradient([RGBAColor])
    case solid(RGBAColor)
    case image(CGImage)
}

struct BackgroundSettings {
    var fill: BackgroundFill
    /// Pixels, relative to the original image size.
    var padding: CGFloat
    var corners: CGFloat
    var shadow: CGFloat
    /// Canvas width / height; nil keeps the image's own proportions plus padding.
    var ratio: CGFloat?
}

/// Draws an image on a gradient/colour/picture canvas with rounded corners and a shadow.
/// Geometry comes from `originalSize`, so a downscaled preview source renders the same layout.
enum BackgroundRenderer {
    static func canvasSize(for size: CGSize, settings: BackgroundSettings) -> CGSize {
        var width = size.width + 2 * settings.padding, height = size.height + 2 * settings.padding
        if let ratio = settings.ratio {
            if width / height < ratio { width = height * ratio } else { height = width / ratio }
        }
        return CGSize(width: width.rounded(), height: height.rounded())
    }

    static func render(_ image: CGImage, originalSize: CGSize, settings: BackgroundSettings,
                       scale: CGFloat = 1) -> CGImage? {
        let canvas = canvasSize(for: originalSize, settings: settings)
        let width = max(1, Int((canvas.width * scale).rounded()))
        let height = max(1, Int((canvas.height * scale).rounded()))
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high

        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        drawBackground(settings.fill, in: context, bounds: bounds, space: space)

        let size = CGSize(width: originalSize.width * scale, height: originalSize.height * scale)
        let rect = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                          width: size.width, height: size.height)
        let radius = min(settings.corners * scale, min(rect.width, rect.height) / 2)
        let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        if settings.shadow > 0 {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -settings.shadow * scale * 0.35),
                              blur: settings.shadow * scale, color: CGColor(gray: 0, alpha: 0.4))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.addPath(shape)
            context.fillPath()
            context.restoreGState()
        }

        context.saveGState()
        context.addPath(shape)
        context.clip()
        context.draw(image, in: rect)
        context.restoreGState()
        return context.makeImage()
    }

    private static func drawBackground(_ fill: BackgroundFill, in context: CGContext, bounds: CGRect, space: CGColorSpace) {
        switch fill {
        case .solid(let color):
            context.setFillColor(cgColor(color))
            context.fill(bounds)
        case .gradient(let colors):
            let cgColors = colors.map(cgColor) as CFArray
            guard let gradient = CGGradient(colorsSpace: space, colors: cgColors, locations: nil) else { return }
            // Top-left → bottom-right (CG's origin is bottom-left).
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: bounds.height),
                                       end: CGPoint(x: bounds.width, y: 0),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        case .image(let picture):
            let factor = max(bounds.width / CGFloat(picture.width), bounds.height / CGFloat(picture.height))
            let size = CGSize(width: CGFloat(picture.width) * factor, height: CGFloat(picture.height) * factor)
            context.draw(picture, in: CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                                             width: size.width, height: size.height))
        }
    }

    private static func cgColor(_ color: RGBAColor) -> CGColor {
        CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }
}

extension RGBAColor {
    static func hex(_ value: UInt32) -> RGBAColor {
        RGBAColor(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255, alpha: 1)
    }
}
