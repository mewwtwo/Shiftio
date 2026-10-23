import CoreImage
import Foundation
import UniformTypeIdentifiers
import Vision

/// Lifts the foreground subject (like Photos' "Copy Subject") into a transparent PNG.
struct RemoveBackgroundAction: FileAction {
    var id: String { "remove-bg" }
    var title: String { String(localized: "Remove BG") }
    var symbol: String? { "person.and.background.dotted" }
    var inputTypes: [UTType] { [.image] }

    func run(_ urls: [URL], options: ActionOptions) async throws -> [URL] {
        try urls.map { url in
            let request = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(url: url)
            try handler.perform([request])
            guard let observation = request.results?.first else {
                throw ShiftioError.emptyResult(String(localized: "no subject found in \(url.lastPathComponent)"))
            }
            let buffer = try observation.generateMaskedImage(ofInstances: observation.allInstances, from: handler,
                                                             croppedToInstancesExtent: false)
            let image = CIImage(cvPixelBuffer: buffer)
            guard let cgImage = CIContext().createCGImage(image, from: image.extent) else {
                throw ShiftioError.unreadable(url)
            }
            let output = OutputNamer.url(for: url, ext: "png", suffix: "no bg")
            try ImageConverter.write(cgImage, to: output, format: .png, properties: nil, options: options)
            return output
        }
    }
}
