import AVFoundation
import Foundation
import UniformTypeIdentifiers

enum MediaFormat: String, CaseIterable, Sendable {
    case mp4, m4a

    var fileType: AVFileType { self == .mp4 ? .mp4 : .m4a }
    var preset: String { self == .mp4 ? AVAssetExportPresetHighestQuality : AVAssetExportPresetAppleM4A }
}

/// Video → MP4, audio/video → M4A via AVFoundation.
struct ConvertMediaAction: FileAction {
    let format: MediaFormat

    var id: String { format.rawValue }
    var title: String { format.rawValue.uppercased() }
    var symbol: String? { format == .m4a ? "waveform" : "film" }
    var inputTypes: [UTType] { format == .mp4 ? [.movie] : [.audiovisualContent] }
    var outputType: UTType? { format == .mp4 ? .mpeg4Movie : .mpeg4Audio }

    func run(_ urls: [URL], options: ActionOptions) async throws -> [URL] {
        var outputs: [URL] = []
        for url in urls {
            let output = OutputNamer.url(for: url, ext: format.rawValue)
            try await MediaConverter.export(url, to: output, format: format)
            outputs.append(output)
        }
        return outputs
    }
}

enum MediaConverter {
    static func export(_ url: URL, to output: URL, format: MediaFormat) async throws {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: format.preset) else {
            throw ShiftioError.unreadable(url)
        }
        try await session.export(to: output, as: format.fileType)
    }
}
