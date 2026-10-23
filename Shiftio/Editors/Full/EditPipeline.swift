import CoreImage
import CoreGraphics

/// The Core Image side of the editor. Adjustments run on the cropped picture, so the vignette follows the crop.
enum EditPipeline {
    /// Analysing a picture for Auto Enhance takes far longer than applying the result, so callers that
    /// render repeatedly compute the chain once and reuse it.
    static func autoFilters(for input: CIImage) -> [CIFilter] {
        input.autoAdjustmentFilters(options: [.redEye: false])
    }

    static func geometry(_ input: CIImage, _ g: EditGeometry, full: CGSize, scale: CGFloat, applyCrop: Bool) -> CIImage {
        var image = input.samplingLinear()
        func normalize() { image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY)) }

        if g.flipH { image = image.transformed(by: CGAffineTransform(scaleX: -1, y: 1)); normalize() }
        if g.flipV { image = image.transformed(by: CGAffineTransform(scaleX: 1, y: -1)); normalize() }
        let turns = ((g.quarterTurns % 4) + 4) % 4
        if turns != 0 {
            image = image.transformed(by: CGAffineTransform(rotationAngle: -.pi / 2 * CGFloat(turns)))
            normalize()
        }
        if g.straighten != 0 {
            let center = CGPoint(x: image.extent.midX, y: image.extent.midY)
            var t = CGAffineTransform(translationX: center.x, y: center.y)
            t = t.rotated(by: -CGFloat(g.straighten) * .pi / 180)
            t = t.translatedBy(x: -center.x, y: -center.y)
            image = image.transformed(by: t)
            normalize()
        }
        guard applyCrop else { return image }

        let crop = EditGeometryMath.crop(full, g)
        let rect = CGRect(x: crop.minX * scale, y: image.extent.height - crop.maxY * scale,
                          width: crop.width * scale, height: crop.height * scale).intersection(image.extent)
        guard !rect.isEmpty else { return image }
        image = image.cropped(to: rect)
        normalize()
        return image
    }

    static func adjust(_ a: EditAdjustments, _ input: CIImage, auto: [CIFilter]?) -> CIImage {
        var image = input
        let extent = input.extent

        if a.autoEnhance, let auto {
            for filter in auto {
                filter.setValue(image, forKey: kCIInputImageKey)
                image = filter.outputImage ?? image
            }
        }
        if a.exposure != 0 {
            image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: a.exposure])
        }
        if a.highlights != 0 || a.shadows != 0 {
            image = image.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 1 + a.highlights, "inputShadowAmount": a.shadows,
            ])
        }
        if a.brightness != 0 || a.contrast != 1 || a.saturation != 1 {
            image = image.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: a.brightness, kCIInputContrastKey: a.contrast, kCIInputSaturationKey: a.saturation,
            ])
        }
        if a.vibrance != 0 {
            image = image.applyingFilter("CIVibrance", parameters: ["inputAmount": a.vibrance])
        }
        if a.warmth != 0 || a.tint != 0 {
            let w = CGFloat(a.warmth), t = CGFloat(a.tint)
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1 + 0.18 * w + 0.06 * t, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1 - 0.12 * t, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1 - 0.18 * w + 0.06 * t, w: 0),
            ])
        }
        if a.fade > 0 {
            // Lifts the blacks and flattens the contrast slightly: the washed-out film look.
            let lift = CGFloat(a.fade) * 0.14
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1 - lift, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1 - lift, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1 - lift, w: 0),
                "inputBiasVector": CIVector(x: lift, y: lift, z: lift, w: 0),
            ])
        }
        if a.noiseReduction > 0 {
            image = image.applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": a.noiseReduction * 0.04, "inputSharpness": 0.4,
            ])
        }
        if a.clarity > 0 {
            // A wide, gentle unsharp mask adds local contrast without crunching fine detail.
            image = image.applyingFilter("CIUnsharpMask", parameters: [
                kCIInputRadiusKey: max(extent.width, extent.height) / 50, kCIInputIntensityKey: a.clarity * 0.9,
            ])
        }
        if a.sharpness > 0 {
            image = image.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: a.sharpness])
        }
        if a.grain > 0 {
            let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!.cropped(to: extent)
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
            let grainy = noise.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: image])
            image = image.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: grainy, kCIInputTimeKey: a.grain * 0.7,
            ])
        }
        if a.vignette > 0 {
            image = image.applyingFilter("CIVignette", parameters: [
                kCIInputIntensityKey: a.vignette * 1.6, kCIInputRadiusKey: 2.0,
            ])
        }
        return image.cropped(to: extent)
    }

    static func filter(_ f: EditFilter, amount: Double, _ input: CIImage) -> CIImage {
        guard f != .none, amount > 0 else { return input }
        let filtered: CIImage
        switch f {
        case .vivid:
            filtered = input
                .applyingFilter("CIVibrance", parameters: ["inputAmount": 0.7])
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.2, kCIInputContrastKey: 1.06])
        case .dramatic:
            filtered = input
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.75, kCIInputContrastKey: 1.3])
                .applyingFilter("CIHighlightShadowAdjust", parameters: ["inputHighlightAmount": 0.7, "inputShadowAmount": 0.3])
        case .sepia:
            filtered = input.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 1])
        default:
            filtered = input.applyingFilter(f.coreImageName!)
        }
        guard amount < 1 else { return filtered }
        return input.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: filtered, kCIInputTimeKey: amount])
    }
}
