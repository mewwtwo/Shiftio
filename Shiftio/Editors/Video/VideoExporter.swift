import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Centred crop to an aspect ratio, applied after rotating and flipping.
enum VideoCrop: String, CaseIterable, Identifiable {
    case original, square, portrait, vertical, wide
    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: String(localized: "Original")
        case .square: "1:1"
        case .portrait: "4:5"
        case .vertical: "9:16"
        case .wide: "16:9"
        }
    }

    var aspect: CGFloat? {
        switch self {
        case .original: nil
        case .square: 1
        case .portrait: 4.0 / 5.0
        case .vertical: 9.0 / 16.0
        case .wide: 16.0 / 9.0
        }
    }
}

/// What the video editor changes.
struct VideoEdit {
    /// The parts that stay, in order. Trimming leaves one; cutting something out of the middle leaves several.
    var segments: [CMTimeRange]
    var muted = false
    var quarterTurns = 0
    var flipped = false
    var crop = VideoCrop.original
    var speed = 1.0
    /// 1 is the original level; the sound can be lifted to 2.
    var volume = 1.0
    /// Seconds from black at the start and to black at the end (the sound fades with them).
    var fadeIn = 0.0
    var fadeOut = 0.0
    var output = SaveFormat.mp4
    var resolution = VideoResolution.original
    var mp3Bitrate = 192
    var gif = GIFOptions()
    /// Whole clips laid after the edited one, in order.
    var joined: [URL] = []
    var stripsMetadata = false
    /// Plays backwards, sound included.
    var reversed = false
    var blurs: [VideoBlur] = []
    var watermark: Watermark?
    /// Burned into the picture, in the time of the saved clip.
    var subtitles: [SubtitleCue] = []
    /// The clip's own sound after noise reduction, on the source's timeline. Cut from instead of the original.
    var alignedAudio: URL?
    /// A file that stands in for the sound, laid from the start of the result.
    var replacementAudio: URL?
    /// What Normalize found; the volume is multiplied by it.
    var normalizeGain = 1.0
    /// Ask the encoder to stay under this many bytes.
    var sizeLimit: Int64?

    var hasOverlays: Bool { !blurs.isEmpty || watermark != nil || !subtitles.isEmpty }
    /// Work that needs the finished picture, so it runs as a second step.
    var needsPost: Bool { reversed || hasOverlays }
    var level: Double { volume * normalizeGain }
    var hasFades: Bool { fadeIn > 0 || fadeOut > 0 }
    var changesPicture: Bool { !joined.isEmpty || quarterTurns % 4 != 0 || flipped || crop != .original || hasFades || resolution != .original }
    var changesSound: Bool { level != 1 || hasFades }
}

/// Everything the editor can save as.
enum SaveFormat: String, CaseIterable, Identifiable {
    case mp4, hevc, prores, gif, m4a, mp3, wav, aiff, flac
    var id: String { rawValue }

    enum Group: String, CaseIterable, Identifiable {
        case video = "Video", animated = "Animated", audio = "Audio"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .video: String(localized: "Video")
            case .animated: String(localized: "Animated")
            case .audio: String(localized: "Audio")
            }
        }
    }

    var group: Group {
        switch self {
        case .mp4, .hevc, .prores: .video
        case .gif: .animated
        default: .audio
        }
    }

    static func formats(in group: Group) -> [SaveFormat] { allCases.filter { $0.group == group } }

    /// Short name, for buttons.
    var title: String {
        switch self {
        case .mp4: "MP4"
        case .hevc: "HEVC"
        case .prores: "ProRes"
        default: rawValue.uppercased()
        }
    }

    /// Name with what it is, for the format menu.
    var menuTitle: String {
        switch self {
        case .mp4: String(localized: "MP4 · H.264, plays everywhere")
        case .hevc: String(localized: "MP4 · HEVC, smaller files")
        case .prores: String(localized: "MOV · ProRes 422, for editing")
        case .gif: String(localized: "GIF · animated picture")
        case .m4a: String(localized: "M4A · AAC")
        case .mp3: "MP3"
        case .wav: String(localized: "WAV · uncompressed")
        case .aiff: String(localized: "AIFF · uncompressed")
        case .flac: String(localized: "FLAC · lossless")
        }
    }

    var fileExtension: String {
        switch self {
        case .hevc: "mp4"
        case .prores: "mov"
        default: rawValue
        }
    }

    var audioFormat: AudioFormat? {
        switch self {
        case .m4a: .m4a
        case .mp3: .mp3
        case .wav: .wav
        case .aiff: .aiff
        case .flac: .flac
        default: nil
        }
    }
}

/// Smaller sizes for video, measured on the short side so portrait clips scale the same way.
enum VideoResolution: String, CaseIterable, Identifiable {
    case original, p1080, p720, p480
    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: String(localized: "Original")
        case .p1080: "1080p"
        case .p720: "720p"
        case .p480: "480p"
        }
    }

    var shortSide: CGFloat? {
        switch self {
        case .original: nil
        case .p1080: 1080
        case .p720: 720
        case .p480: 480
        }
    }
}

struct GIFOptions: Equatable {
    var fps = 12
    var width = 480
    static let frameRates = [8, 12, 15, 20]
    static let widths = [320, 480, 640]
}

/// Trim, mute, speed, rotate, flip and crop through an AVMutableComposition. The preview and the saved file
/// share `layout`, so what the window shows is what gets written.
@MainActor
enum VideoExporter {
    static let speeds = [0.5, 1, 1.5, 2]

    /// A clip laid after the edited one, on its own track.
    struct Join {
        let track: AVMutableCompositionTrack
        let source: AVAssetTrack
        let range: CMTimeRange
    }

    /// A render that turns, flips and crops `source`. nil when the picture is left as it is.
    /// Joined clips are fitted whole into the same frame, with black bars where the shapes differ.
    static func layout(source: AVAssetTrack, target: AVAssetTrack, duration: CMTime, edit: VideoEdit, joins: [Join] = []) async throws -> AVMutableVideoComposition? {
        guard edit.changesPicture else { return nil }
        let mainEnd = joins.first?.range.start ?? duration
        let lastLength = joins.last?.range.duration ?? duration
        let fadeIn = min(edit.fadeIn, mainEnd.seconds / 2), fadeOut = min(edit.fadeOut, lastLength.seconds / 2)
        let turns = ((edit.quarterTurns % 4) + 4) % 4
        let (size, base, frame) = try await source.load(.naturalSize, .preferredTransform, .minFrameDuration)

        var transform = base.concatenating(CGAffineTransform(rotationAngle: .pi / 2 * CGFloat(turns)))
        if edit.flipped { transform = transform.concatenating(CGAffineTransform(scaleX: -1, y: 1)) }
        let bounds = CGRect(origin: .zero, size: size).applying(transform)
        transform = transform.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))

        var render = bounds.size
        if let aspect = edit.crop.aspect {
            var width = bounds.width, height = bounds.height
            if width / height > aspect { width = height * aspect } else { height = width / aspect }
            // Encoders want even dimensions.
            render = CGSize(width: max(2, (width / 2).rounded(.down) * 2), height: max(2, (height / 2).rounded(.down) * 2))
            transform = transform.concatenating(CGAffineTransform(translationX: -(bounds.width - render.width) / 2,
                                                                  y: -(bounds.height - render.height) / 2))
        }

        if let shortSide = edit.resolution.shortSide, min(render.width, render.height) > shortSide {
            let scale = shortSide / min(render.width, render.height)
            transform = transform.concatenating(CGAffineTransform(scaleX: scale, y: scale))
            render = CGSize(width: max(2, (render.width * scale / 2).rounded() * 2), height: max(2, (render.height * scale / 2).rounded() * 2))
        }

        func fadeInRamp(_ layer: AVMutableVideoCompositionLayerInstruction) {
            guard fadeIn > 0 else { return }
            // Over the composition's black background, so fading the picture is fading to black.
            layer.setOpacityRamp(fromStartOpacity: 0, toEndOpacity: 1, timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: fadeIn, preferredTimescale: 600)))
        }
        func fadeOutRamp(_ layer: AVMutableVideoCompositionLayerInstruction) {
            guard fadeOut > 0 else { return }
            let length = CMTime(seconds: fadeOut, preferredTimescale: 600)
            layer.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0, timeRange: CMTimeRange(start: duration - length, duration: length))
        }

        let main = AVMutableVideoCompositionLayerInstruction(assetTrack: target)
        main.setTransform(transform, at: .zero)
        fadeInRamp(main)
        if joins.isEmpty { fadeOutRamp(main) }
        let first = AVMutableVideoCompositionInstruction()
        first.timeRange = CMTimeRange(start: .zero, duration: mainEnd)
        first.layerInstructions = [main]
        var instructions = [first]

        for (index, join) in joins.enumerated() {
            let (natural, preferred) = try await join.source.load(.naturalSize, .preferredTransform)
            let box = CGRect(origin: .zero, size: natural).applying(preferred)
            guard box.width > 0, box.height > 0 else { continue }
            let scale = min(render.width / box.width, render.height / box.height)
            let fitted = preferred
                .concatenating(CGAffineTransform(translationX: -box.minX, y: -box.minY))
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: (render.width - box.width * scale) / 2, y: (render.height - box.height * scale) / 2))
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: join.track)
            layer.setTransform(fitted, at: join.range.start)
            if index == joins.count - 1 { fadeOutRamp(layer) }
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = join.range
            instruction.layerInstructions = [layer]
            instructions.append(instruction)
        }

        let composition = AVMutableVideoComposition()
        composition.instructions = instructions
        composition.renderSize = render
        composition.frameDuration = frame.isValid && frame.seconds > 0 ? frame : CMTime(value: 1, timescale: 30)
        return composition
    }

    /// Level and fades of the sound. nil when it is left alone.
    static func audioMix(for tracks: [AVAssetTrack], duration: CMTime, edit: VideoEdit) -> AVMutableAudioMix? {
        guard edit.changesSound, !tracks.isEmpty else { return nil }
        let fadeIn = min(edit.fadeIn, duration.seconds / 2), fadeOut = min(edit.fadeOut, duration.seconds / 2)
        let level = Float(edit.level)
        let mix = AVMutableAudioMix()
        mix.inputParameters = tracks.map { track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(level, at: .zero)
            if fadeIn > 0 {
                parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: level,
                                         timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: fadeIn, preferredTimescale: 600)))
            }
            if fadeOut > 0 {
                let length = CMTime(seconds: fadeOut, preferredTimescale: 600)
                parameters.setVolumeRamp(fromStartVolume: level, toEndVolume: 0, timeRange: CMTimeRange(start: duration - length, duration: length))
            }
            return parameters
        }
        return mix
    }

    static func export(_ url: URL, edit: VideoEdit, to output: URL) async throws {
        do {
            switch edit.output.group {
            case .audio: try await writeAudio(url, edit: edit, to: output)
            case _ where edit.needsPost: try await writeStaged(url, edit: edit, to: output)
            case .video: try await writeVideo(url, edit: edit, to: output)
            case .animated: try await writeGIF(url, edit: edit, to: output)
            }
        } catch {
            try? FileManager.default.removeItem(at: output)
            OutputNamer.removePartials(of: output)
            throw error
        }
    }

    /// Reversing and overlays work on the finished picture, so the edit is rendered first, then reversed, then written in the
    /// chosen format with the overlays on top.
    private static func writeStaged(_ url: URL, edit: VideoEdit, to output: URL) async throws {
        let manager = FileManager.default
        var temporary: [URL] = []
        defer { temporary.forEach { try? manager.removeItem(at: $0) } }
        func scratch(_ ext: String) -> URL {
            let file = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
            temporary.append(file)
            return file
        }

        var first = edit
        first.output = .hevc
        first.stripsMetadata = false
        first.sizeLimit = nil
        first.blurs = []
        first.watermark = nil
        first.subtitles = []
        first.reversed = false
        // Backwards, the end becomes the start.
        if edit.reversed { (first.fadeIn, first.fadeOut) = (edit.fadeOut, edit.fadeIn) }
        var current = scratch("mp4")
        try await writeVideo(url, edit: first, to: current)

        var soundtrack: URL?
        if edit.reversed {
            let picture = scratch("mov"), sound = scratch("caf")
            if try await VideoReverse.reverse(current, video: picture, audio: sound) { soundtrack = sound }
            current = picture
        }

        let asset = AVURLAsset(url: current)
        var last = VideoEdit(segments: [CMTimeRange(start: .zero, duration: try await asset.load(.duration))])
        last.output = edit.output
        last.gif = edit.gif
        last.stripsMetadata = edit.stripsMetadata
        last.sizeLimit = edit.sizeLimit
        last.replacementAudio = soundtrack
        let overlay = OverlayRenderer.make(for: edit, size: try await pictureSize(of: asset))
        if edit.output.group == .animated {
            try await writeGIF(current, edit: last, to: output, overlay: overlay)
        } else {
            try await writeVideo(current, edit: last, to: output, overlay: overlay, metadataSource: url)
        }
    }

    /// The picture as it is shown, turned the right way up.
    private static func pictureSize(of asset: AVAsset) async throws -> CGSize {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ShiftioError.unreadable((asset as? AVURLAsset)?.url ?? URL(fileURLWithPath: "/")) }
        let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
        return CGRect(origin: .zero, size: size).applying(transform).size
    }

    /// Size of the saved file, asked of the encoder without encoding. nil for GIF and when the encoder cannot say.
    static func estimatedSize(_ url: URL, edit: VideoEdit) async -> Int64? {
        let seconds: Double
        switch edit.output.group {
        case .animated:
            return nil
        case .audio:
            guard let built = try? await build(url, edit: edit, video: false, audio: true) else { return nil }
            seconds = built.composition.duration.seconds
            // Everything but M4A is made from the edited sound by a converter, so there is no encoder to ask.
            switch edit.output {
            case .mp3: return Int64(Double(edit.mp3Bitrate) * 125 * seconds)
            case .wav, .aiff: return Int64(176_400 * seconds)
            case .flac: return Int64(100_000 * seconds)
            default: break
            }
            guard let session = AVAssetExportSession(asset: built.composition, presetName: AVAssetExportPresetAppleM4A) else { return nil }
            return try? await session.estimatedOutputFileLengthInBytes
        case .video:
            guard let built = try? await build(url, edit: edit, video: true, audio: true) else { return nil }
            let preset = switch edit.output {
            case .hevc: AVAssetExportPresetHEVCHighestQuality
            case .prores: AVAssetExportPresetAppleProRes422LPCM
            default: AVAssetExportPresetHighestQuality
            }
            guard let session = AVAssetExportSession(asset: built.composition, presetName: preset) else { return nil }
            if let video = built.video, let source = built.sourceVideo {
                session.videoComposition = try? await layout(source: source, target: video, duration: built.composition.duration, edit: edit, joins: built.joins)
            }
            guard let estimate = try? await session.estimatedOutputFileLengthInBytes else { return nil }
            // The encoder is asked to stay under the limit, so the file can't be bigger than it.
            return edit.output != .prores ? min(estimate, edit.sizeLimit ?? estimate) : estimate
        }
    }

    private struct Built {
        let composition: AVMutableComposition
        let video: AVMutableCompositionTrack?
        let sourceVideo: AVAssetTrack?
        let audio: AVMutableCompositionTrack?
        let joins: [Join]
    }

    /// The kept pieces laid end to end, then sped up or slowed down as a whole.
    private static func build(_ url: URL, edit: VideoEdit, video wantsVideo: Bool, audio wantsAudio: Bool) async throws -> Built {
        let asset = AVURLAsset(url: url)
        let composition = AVMutableComposition()

        var sourceVideo: AVAssetTrack?
        var videoTrack: AVMutableCompositionTrack?
        if wantsVideo {
            guard let source = try await asset.loadTracks(withMediaType: .video).first,
                  let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { throw ShiftioError.unreadable(url) }
            track.preferredTransform = try await source.load(.preferredTransform)
            sourceVideo = source
            videoTrack = track
        }
        var sourceAudio: AVAssetTrack?
        var audioTrack: AVMutableCompositionTrack?
        if wantsAudio, !edit.muted {
            // Noise reduction made a copy of the sound on the source's timeline; cut from that instead of the original.
            let soundAsset = edit.alignedAudio.map { AVURLAsset(url: $0) } ?? asset
            if edit.replacementAudio != nil {
                audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            } else if let source = try await soundAsset.loadTracks(withMediaType: .audio).first {
                sourceAudio = source
                audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            }
        }
        if wantsAudio, !wantsVideo, audioTrack == nil {
            throw ShiftioError.emptyResult(edit.muted ? String(localized: "the sound is switched off") : String(localized: "this video has no sound"))
        }

        var cursor = CMTime.zero
        for segment in edit.segments {
            if let videoTrack, let sourceVideo { try videoTrack.insertTimeRange(segment, of: sourceVideo, at: cursor) }
            if let audioTrack, let sourceAudio { try audioTrack.insertTimeRange(segment, of: sourceAudio, at: cursor) }
            cursor = cursor + segment.duration
        }
        guard cursor > .zero else { throw ShiftioError.emptyResult(String(localized: "everything was cut out")) }

        if edit.speed != 1 {
            let whole = CMTimeRange(start: .zero, duration: composition.duration)
            composition.scaleTimeRange(whole, toDuration: CMTimeMultiplyByFloat64(whole.duration, multiplier: 1 / edit.speed))
        }

        // Joined clips go after the edited one, which has already been sped up or slowed down.
        var joins: [Join] = []
        for extra in edit.joined {
            let other = AVURLAsset(url: extra)
            let length = try await other.load(.duration)
            guard length > .zero else { continue }
            let range = CMTimeRange(start: .zero, duration: length)
            let start = composition.duration
            if wantsVideo {
                guard let source = try await other.loadTracks(withMediaType: .video).first,
                      let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                else { throw ShiftioError.unreadable(extra) }
                try track.insertTimeRange(range, of: source, at: start)
                joins.append(Join(track: track, source: source, range: CMTimeRange(start: start, duration: length)))
            }
            if wantsAudio, !edit.muted, edit.replacementAudio == nil, let source = try await other.loadTracks(withMediaType: .audio).first {
                if audioTrack == nil {
                    audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                }
                try audioTrack?.insertTimeRange(range, of: source, at: start)
            }
        }

        if let replacement = edit.replacementAudio, let audioTrack {
            let other = AVURLAsset(url: replacement)
            guard let source = try await other.loadTracks(withMediaType: .audio).first else { throw ShiftioError.unreadable(replacement) }
            let length = min(try await other.load(.duration), composition.duration)
            try audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: source, at: .zero)
        }
        return Built(composition: composition, video: videoTrack, sourceVideo: sourceVideo, audio: audioTrack, joins: joins)
    }

    /// An export of a composition carries no tags of its own, so the source's are copied over, or left out when asked.
    private static func applyMetadata(to session: AVAssetExportSession, from source: URL, strip: Bool) async {
        if strip {
            session.metadata = []
            session.metadataItemFilter = .forSharing()
        } else if let items = try? await AVURLAsset(url: source).load(.metadata) {
            session.metadata = items
        }
    }

    private static func writeVideo(_ url: URL, edit: VideoEdit, to output: URL, overlay: OverlayRenderer? = nil, metadataSource: URL? = nil) async throws {
        let built = try await build(url, edit: edit, video: true, audio: true)
        let (preset, fileType): (String, AVFileType) = switch edit.output {
        case .hevc: (AVAssetExportPresetHEVCHighestQuality, .mp4)
        case .prores: (AVAssetExportPresetAppleProRes422LPCM, .mov)
        default: (AVAssetExportPresetHighestQuality, .mp4)
        }
        let picture: AVVideoComposition?
        if let overlay {
            picture = try await overlay.composition(for: built.composition)
        } else if let video = built.video, let source = built.sourceVideo {
            picture = try await layout(source: source, target: video, duration: built.composition.duration, edit: edit, joins: built.joins)
        } else {
            picture = nil
        }
        let mix = built.audio.flatMap { audioMix(for: [$0], duration: built.composition.duration, edit: edit) }

        // A size limit needs an encoder that can be given a bitrate, which the export presets can't.
        if let limit = edit.sizeLimit, edit.output != .prores {
            let metadata = edit.stripsMetadata ? [] : ((try? await AVURLAsset(url: metadataSource ?? url).load(.metadata)) ?? [])
            try await VideoSizedWriter.write(.init(composition: built.composition, videoComposition: picture, audioMix: mix, metadata: metadata,
                                                   hevc: edit.output == .hevc, bytes: limit, seconds: built.composition.duration.seconds), to: output)
            return
        }

        guard let session = AVAssetExportSession(asset: built.composition, presetName: preset)
        else { throw ShiftioError.unavailable(edit.output.title) }
        session.audioTimePitchAlgorithm = .spectral
        session.videoComposition = picture
        await applyMetadata(to: session, from: metadataSource ?? url, strip: edit.stripsMetadata)
        session.audioMix = mix
        try await session.export(to: output, as: fileType)
    }

    private static func writeAudio(_ url: URL, edit: VideoEdit, to output: URL) async throws {
        let built = try await build(url, edit: edit, video: false, audio: true)
        guard let session = AVAssetExportSession(asset: built.composition, presetName: AVAssetExportPresetAppleM4A)
        else { throw ShiftioError.unreadable(url) }
        session.audioTimePitchAlgorithm = .spectral
        session.audioMix = built.audio.flatMap { audioMix(for: [$0], duration: built.composition.duration, edit: edit) }
        await applyMetadata(to: session, from: url, strip: edit.stripsMetadata)

        guard let format = edit.output.audioFormat, format != .m4a else {
            try await session.export(to: output, as: .m4a)
            return
        }
        // MP3, WAV, AIFF and FLAC are made from the edited sound, through the same converter as the Audio action.
        let edited = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: edited) }
        try await session.export(to: edited, as: .m4a)
        try await AudioConverter.convert(edited, to: output, format: format, options: ActionOptions(mp3Bitrate: edit.mp3Bitrate))
    }

    /// Frames at a fixed rate through the same layout as the video, so cuts, speed, turns and crop all carry over.
    private static func writeGIF(_ url: URL, edit: VideoEdit, to output: URL, overlay: OverlayRenderer? = nil) async throws {
        let built = try await build(url, edit: edit, video: true, audio: false)
        let duration = built.composition.duration
        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: edit.gif.width, height: 4096)
        if let overlay {
            generator.videoComposition = try await overlay.composition(for: built.composition)
        } else if let video = built.video, let source = built.sourceVideo {
            generator.videoComposition = try await layout(source: source, target: video, duration: duration, edit: edit, joins: built.joins)
        }

        // GIF delays are whole hundredths of a second; stepping by one keeps the playing time true.
        let step = max(0.02, (100 / Double(edit.gif.fps)).rounded() / 100)
        let count = min(900, max(1, Int((duration.seconds / step).rounded())))
        let times = (0..<count).map { CMTime(seconds: min(Double($0) * step, duration.seconds - 0.001), preferredTimescale: 600) }
        var frames = [CGImage?](repeating: nil, count: count)
        for await result in generator.images(for: times) {
            guard let image = try? result.image, let index = times.firstIndex(where: { CMTimeCompare($0, result.requestedTime) == 0 }) else { continue }
            frames[index] = image
        }

        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, count, nil)
        else { throw ShiftioError.writeFailed(output) }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let delay = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: step]] as CFDictionary
        var written = 0
        for case let frame? in frames {
            CGImageDestinationAddImage(destination, frame, delay)
            written += 1
        }
        guard written > 0, CGImageDestinationFinalize(destination) else { throw ShiftioError.writeFailed(output) }
    }

    /// One picture from the video as PNG, through the same layout as the preview.
    static func writeFrame(of asset: AVAsset, at time: CMTime, layout: AVVideoComposition?, to output: URL) async throws {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.videoComposition = layout
        var picture: CGImage?
        for await result in generator.images(for: [time]) { picture = try result.image }
        guard let image = picture, let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw ShiftioError.writeFailed(output) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ShiftioError.writeFailed(output) }
    }
}
