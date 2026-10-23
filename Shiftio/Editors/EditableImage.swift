import CoreGraphics
import Foundation
import ImageIO

/// An image loaded with its EXIF orientation applied, plus the metadata to carry over on save.
struct EditableImage {
    let url: URL
    let image: CGImage
    private let properties: [CFString: Any]

    var pixelSize: CGSize { CGSize(width: image.width, height: image.height) }

    init(url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { throw ShiftioError.unreadable(url) }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { throw ShiftioError.unreadable(url) }

        self.url = url
        self.image = image
        self.properties = props
    }

    /// Metadata for writing `image` back: pixel orientation is already baked in.
    var outputProperties: [CFString: Any] {
        var props = properties
        props[kCGImagePropertyOrientation] = 1
        props[kCGImagePropertyPixelWidth] = nil
        props[kCGImagePropertyPixelHeight] = nil
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            props[kCGImagePropertyTIFFDictionary] = tiff
        }
        return props
    }
}

extension ImageFormat {
    /// Keeps the source's format when saving an edit; unknown formats become PNG.
    init(matching url: URL) {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": self = .jpg
        case "heic", "heif": self = .heic
        case "tif", "tiff": self = .tiff
        case "gif": self = .gif
        case "bmp": self = .bmp
        default: self = .png
        }
    }
}

extension CGImage {
    /// Downscaled copy for fast previews; returns self when already small enough.
    func scaled(maxSide: CGFloat) -> CGImage {
        let longest = CGFloat(max(width, height))
        guard longest > maxSide else { return self }
        let factor = maxSide / longest
        let w = Int((CGFloat(width) * factor).rounded()), h = Int((CGFloat(height) * factor).rounded())
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return self }
        context.interpolationQuality = .high
        context.draw(self, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage() ?? self
    }
}
