import CoreGraphics
import Foundation

// MARK: Adjustments

struct EditAdjustments: Equatable {
    var autoEnhance = false
    // Light
    var exposure = 0.0       // EV, -2...2
    var brightness = 0.0     // -0.5...0.5
    var contrast = 1.0       // 0.5...1.5
    var highlights = 0.0     // -1...0, pulls bright areas down
    var shadows = 0.0        // -1...1, lifts or deepens dark areas
    // Color
    var saturation = 1.0     // 0...2
    var vibrance = 0.0       // -1...1
    var warmth = 0.0         // -1...1
    var tint = 0.0           // -1 green … 1 magenta
    // Detail
    var sharpness = 0.0      // 0...2
    var clarity = 0.0        // 0...1
    var noiseReduction = 0.0 // 0...1
    // Effects
    var fade = 0.0           // 0...1
    var grain = 0.0          // 0...1
    var vignette = 0.0       // 0...1

    enum Group: String, CaseIterable, Identifiable {
        case light, color, detail, effects
        var id: String { rawValue }
        var title: String {
            switch self {
            case .light: String(localized: "edit.light", defaultValue: "Light")
            case .color: String(localized: "Color")
            case .detail: String(localized: "Detail")
            case .effects: String(localized: "Effects")
            }
        }
        var symbol: String {
            switch self {
            case .light: "sun.max"
            case .color: "paintpalette"
            case .detail: "triangle"
            case .effects: "sparkles"
            }
        }
    }

    mutating func reset(_ group: Group) {
        let d = EditAdjustments()
        switch group {
        case .light: (exposure, brightness, contrast, highlights, shadows) = (d.exposure, d.brightness, d.contrast, d.highlights, d.shadows)
        case .color: (saturation, vibrance, warmth, tint) = (d.saturation, d.vibrance, d.warmth, d.tint)
        case .detail: (sharpness, clarity, noiseReduction) = (d.sharpness, d.clarity, d.noiseReduction)
        case .effects: (fade, grain, vignette) = (d.fade, d.grain, d.vignette)
        }
    }

    func isModified(_ group: Group) -> Bool {
        var copy = self
        copy.reset(group)
        return copy != self
    }
}

enum EditFilter: String, CaseIterable, Identifiable {
    case none, vivid, dramatic, mono, silvertone, noir, chrome, fade, instant, process, transfer, sepia

    var id: String { rawValue }
    var title: String { self == .none ? String(localized: "Original") : rawValue.capitalized }

    /// Core Image's ready-made photo effects; Vivid and Dramatic are built from adjustments.
    var coreImageName: String? {
        switch self {
        case .mono: "CIPhotoEffectMono"
        case .silvertone: "CIPhotoEffectTonal"
        case .noir: "CIPhotoEffectNoir"
        case .chrome: "CIPhotoEffectChrome"
        case .fade: "CIPhotoEffectFade"
        case .instant: "CIPhotoEffectInstant"
        case .process: "CIPhotoEffectProcess"
        case .transfer: "CIPhotoEffectTransfer"
        case .sepia: "CISepiaTone"
        case .none, .vivid, .dramatic: nil
        }
    }
}

// MARK: Geometry

enum EditAspect: String, CaseIterable, Identifiable {
    case original, free, square, r43, r34, r32, r23, r169, r916

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: String(localized: "Original")
        case .free: String(localized: "Free")
        case .square: "1:1"
        case .r43: "4:3"
        case .r34: "3:4"
        case .r32: "3:2"
        case .r23: "2:3"
        case .r169: "16:9"
        case .r916: "9:16"
        }
    }

    /// Width / height, or nil for free-form.
    func ratio(for oriented: CGSize) -> CGFloat? {
        switch self {
        case .original: oriented.width / oriented.height
        case .free: nil
        case .square: 1
        case .r43: 4.0 / 3
        case .r34: 3.0 / 4
        case .r32: 3.0 / 2
        case .r23: 2.0 / 3
        case .r169: 16.0 / 9
        case .r916: 9.0 / 16
        }
    }
}

struct EditGeometry: Equatable {
    var quarterTurns = 0
    var flipH = false
    var flipV = false
    /// Degrees, -45...45; positive turns the picture clockwise.
    var straighten = 0.0
    var aspect = EditAspect.original
    /// Crop in pixels of the straightened canvas, top-left origin. nil = the largest rectangle that fits.
    var crop: CGRect?
}

/// All sizes are in pixels of the full-resolution image; previews scale them down.
enum EditGeometryMath {
    static func oriented(_ full: CGSize, _ g: EditGeometry) -> CGSize {
        g.quarterTurns % 2 == 0 ? full : CGSize(width: full.height, height: full.width)
    }

    /// Bounding box of the picture after straightening.
    static func canvasSize(_ full: CGSize, _ g: EditGeometry) -> CGSize {
        let o = oriented(full, g)
        let a = abs(g.straighten) * .pi / 180
        guard a > 0 else { return o }
        return CGSize(width: (o.width * cos(a) + o.height * sin(a)).rounded(),
                      height: (o.width * sin(a) + o.height * cos(a)).rounded())
    }

    /// The biggest rectangle with the picture's own proportions that stays inside the tilted picture.
    static func inscribedRect(_ full: CGSize, _ g: EditGeometry) -> CGRect {
        let o = oriented(full, g)
        let canvas = canvasSize(full, g)
        let a = abs(g.straighten) * .pi / 180
        let long = max(o.width, o.height), short = min(o.width, o.height)
        let k = 1 / (cos(a) + (long / short) * sin(a))
        let size = CGSize(width: (o.width * k).rounded(.down), height: (o.height * k).rounded(.down))
        return CGRect(x: ((canvas.width - size.width) / 2).rounded(), y: ((canvas.height - size.height) / 2).rounded(),
                      width: size.width, height: size.height)
    }

    /// The crop that applies now: the user's, or the automatic one fitted to the chosen proportions.
    static func crop(_ full: CGSize, _ g: EditGeometry) -> CGRect {
        if let crop = g.crop { return crop }
        let inscribed = inscribedRect(full, g)
        guard let ratio = g.aspect.ratio(for: oriented(full, g)) else { return inscribed }
        return CropMath.fit(inscribed, ratio: ratio).integral
    }
}

// MARK: Whole state

struct EditState: Equatable {
    var adjustments = EditAdjustments()
    var filter = EditFilter.none
    var filterAmount = 1.0
    var geometry = EditGeometry()
    var annotations: [Annotation] = []

    var isUntouched: Bool { self == EditState() }
}

// MARK: Export

enum ExportFormat: String, CaseIterable, Identifiable {
    case original, jpg, png, heic, tiff

    var id: String { rawValue }
    var title: String { self == .original ? String(localized: "Same as original") : rawValue.uppercased() }
    var usesQuality: Bool { self == .jpg || self == .heic }

    func imageFormat(matching source: URL) -> ImageFormat {
        switch self {
        case .original: ImageFormat(matching: source)
        case .jpg: .jpg
        case .png: .png
        case .heic: .heic
        case .tiff: .tiff
        }
    }
}

struct ExportOptions: Equatable {
    var format = ExportFormat.original
    var quality = 0.9
    /// Longest side in pixels; 0 keeps the size.
    var maxSide = 0
    var keepMetadata = true
    var removeLocation = false
}
