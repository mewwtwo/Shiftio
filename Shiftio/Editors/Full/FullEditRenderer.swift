import CoreImage
import CoreGraphics

struct EditHistogram: Equatable, Sendable {
    var red = [Int](repeating: 0, count: 256)
    var green = [Int](repeating: 0, count: 256)
    var blue = [Int](repeating: 0, count: 256)
    var luma = [Int](repeating: 0, count: 256)

    var peak: Int { max(1, [red, green, blue, luma].map { $0.dropFirst().dropLast().max() ?? 0 }.max() ?? 1) }

    static func compute(_ image: CGImage) -> EditHistogram {
        let small = image.scaled(maxSide: 160)
        let width = small.width, height = small.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(small, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        var histogram = EditHistogram()
        guard drawn else { return histogram }
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index + 3] > 8 {
            let r = Int(pixels[index]), g = Int(pixels[index + 1]), b = Int(pixels[index + 2])
            histogram.red[r] += 1
            histogram.green[g] += 1
            histogram.blue[b] += 1
            histogram.luma[(r * 299 + g * 587 + b * 114) / 1000] += 1
        }
        return histogram
    }
}

/// Renders the editor's picture off the main thread. Calls run one at a time; a render that was superseded
/// by a newer slider position is skipped, and Auto Enhance is analysed once and reused.
actor FullEditRenderer {
    enum Mode {
        /// Cropped, adjusted and filtered: what will be saved.
        case result
        /// The whole straightened picture, for the crop tool.
        case canvas
        /// Same framing, edits removed (the "hold to compare" view).
        case original
    }

    private let full: CGImage
    private var sources: [Int: (image: CIImage, scale: CGFloat)] = [:]
    private var autoChain: [CIFilter]?
    private let fullSize: CGSize
    nonisolated(unsafe) private static let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    init(full: CGImage) {
        self.full = full
        fullSize = CGSize(width: full.width, height: full.height)
    }

    private func source(maxSide: Int) -> (image: CIImage, scale: CGFloat) {
        let side = min(maxSide, max(full.width, full.height))
        if let cached = sources[side] { return cached }
        let cg = side >= max(full.width, full.height) ? full : full.scaled(maxSide: CGFloat(side))
        let entry = (image: CIImage(cgImage: cg), scale: CGFloat(cg.width) / fullSize.width)
        sources[side] = entry
        return entry
    }

    private func chain(if needed: Bool) -> [CIFilter]? {
        guard needed else { return nil }
        if autoChain == nil { autoChain = EditPipeline.autoFilters(for: source(maxSide: 640).image) }
        return autoChain
    }

    /// Compiles the Core Image kernels up front so the first slider drag doesn't stall.
    func warmUp() {
        var state = EditState()
        state.adjustments = EditAdjustments(autoEnhance: true, exposure: 0.1, brightness: 0.01, contrast: 1.01,
                                            highlights: -0.1, shadows: 0.1, saturation: 1.01, vibrance: 0.1,
                                            warmth: 0.1, tint: 0.1, sharpness: 0.1, clarity: 0.1, noiseReduction: 0.1,
                                            fade: 0.1, grain: 0.1, vignette: 0.1)
        state.geometry.straighten = 0.5
        _ = render(state, maxSide: 96, mode: .result)
        for filter in EditFilter.allCases where filter != .none {
            var s = EditState()
            s.filter = filter
            _ = render(s, maxSide: 96, mode: .result)
        }
    }

    func render(_ state: EditState, maxSide: Int, mode: Mode) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let (input, scale) = source(maxSide: maxSide)
        var image = EditPipeline.geometry(input, state.geometry, full: fullSize, scale: scale, applyCrop: mode != .canvas)
        if mode != .original {
            image = EditPipeline.adjust(state.adjustments, image, auto: chain(if: state.adjustments.autoEnhance))
            image = EditPipeline.filter(state.filter, amount: state.filterAmount, image)
        }
        return makeImage(image)
    }

    /// One small preview per filter, of the current framing and adjustments.
    func thumbnails(_ state: EditState) -> [EditFilter: CGImage] {
        guard !Task.isCancelled else { return [:] }
        let (input, scale) = source(maxSide: 200)
        var base = EditPipeline.geometry(input, state.geometry, full: fullSize, scale: scale, applyCrop: true)
        base = EditPipeline.adjust(state.adjustments, base, auto: chain(if: state.adjustments.autoEnhance))
        var result: [EditFilter: CGImage] = [:]
        for filter in EditFilter.allCases {
            if Task.isCancelled { break }
            if let image = makeImage(EditPipeline.filter(filter, amount: 1, base)) { result[filter] = image }
        }
        return result
    }

    func renderFinal(_ state: EditState) -> CGImage? {
        render(state, maxSide: .max, mode: .result)
    }

    private func makeImage(_ image: CIImage) -> CGImage? {
        guard !image.extent.isInfinite, !image.extent.isEmpty else { return nil }
        return Self.context.createCGImage(image, from: image.extent, format: .RGBA8,
                                          colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
}
