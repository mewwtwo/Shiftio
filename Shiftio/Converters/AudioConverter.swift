import AVFoundation
import Foundation
import UniformTypeIdentifiers

enum AudioFormat: String, CaseIterable, Codable, Identifiable, Sendable {
    case mp3, m4a, wav, aiff, flac

    var id: String { rawValue }
    var title: String { rawValue.uppercased() }

    var type: UTType {
        switch self {
        case .mp3: .mp3
        case .m4a: .mpeg4Audio
        case .wav: .wav
        case .aiff: .aiff
        case .flac: UTType("org.xiph.flac") ?? UTType(filenameExtension: "flac") ?? .audio
        }
    }
}

/// Audio (or the sound track of a video) → MP3, M4A, WAV, AIFF or FLAC.
/// With `format == nil` the target is the default chosen in Settings, shown in the ring under its own name.
struct ConvertAudioAction: FileAction {
    let format: AudioFormat?

    var id: String { format?.rawValue ?? "audio" }
    var title: String { format?.title ?? String(localized: "Audio") }
    var inputTypes: [UTType] { [.audiovisualContent] }
    var outputType: UTType? { format?.type }

    func displayTitle(options: ActionOptions) -> String { format?.title ?? options.audioFormat.title }

    func run(_ urls: [URL], options: ActionOptions) async throws -> [URL] {
        let target = format ?? options.audioFormat
        var outputs: [URL] = []
        for url in urls {
            let output = OutputNamer.url(for: url, ext: target.rawValue)
            try await AudioConverter.convert(url, to: output, format: target, options: options)
            outputs.append(output)
        }
        return outputs
    }
}

/// AVFoundation has no MP3 encoder, so MP3 goes through LAME. Shiftio downloads its own copy on first launch
/// (see `ComponentInstaller`); a Homebrew copy already on the Mac works as a fallback.
enum MP3Encoder {
    struct Located {
        let path: String
        /// True for the copy Shiftio installed itself.
        let isManaged: Bool
    }

    static func locate() -> Located? {
        let installed = ComponentInstaller.directory.appendingPathComponent("lame/lame").path
        if FileManager.default.isExecutableFile(atPath: installed) { return Located(path: installed, isManaged: true) }
        return ["/opt/homebrew/bin/lame", "/usr/local/bin/lame", "/opt/local/bin/lame"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { Located(path: $0, isManaged: false) }
    }
}

enum AudioConverter {
    static func convert(_ url: URL, to output: URL, format: AudioFormat, options: ActionOptions) async throws {
        switch format {
        case .m4a: try await MediaConverter.export(url, to: output, format: .m4a)
        case .mp3: try await encodeMP3(url, to: output, bitrate: options.mp3Bitrate)
        case .wav, .aiff, .flac: try await writePCM(url, to: output, format: format)
        }
    }

    private static func encodeMP3(_ url: URL, to output: URL, bitrate: Int) async throws {
        guard let lame = MP3Encoder.locate() else {
            throw ShiftioError.encoderMissing("MP3", String(localized: "open Shiftio → Settings → General → Components, and download it (needs internet)"))
        }
        // lame only reads PCM files, so decode to a temporary WAV first.
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        try await writePCM(url, to: wav, format: .wav)

        var arguments = ["--quiet", "-b", "\(bitrate)"]
        let tags = await tags(of: url)
        for (flag, value) in [("--tt", tags.title), ("--ta", tags.artist), ("--tl", tags.album)] {
            if let value, !value.isEmpty { arguments += [flag, value] }
        }
        arguments += [wav.path, output.path]
        do {
            try await Shell.runAsync(lame.path, arguments)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    /// Title, artist and album carry over to the MP3's ID3 tags when the source has them.
    private static func tags(of url: URL) async -> (title: String?, artist: String?, album: String?) {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata) else { return (nil, nil, nil) }
        func value(_ key: AVMetadataKey) async -> String? {
            guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .init(rawValue: "common/\(key.rawValue)")).first
            else { return nil }
            return try? await item.load(.stringValue)
        }
        return (await value(.commonKeyTitle), await value(.commonKeyArtist), await value(.commonKeyAlbumName))
    }

    private static func writePCM(_ url: URL, to output: URL, format: AudioFormat) async throws {
        // Video containers and some codecs can't be read as audio files; take the sound track out first.
        var source = url
        var temporary: URL?
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
        if (try? AVAudioFile(forReading: url)) == nil {
            let extracted = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
            try await MediaConverter.export(url, to: extracted, format: .m4a)
            source = extracted
            temporary = extracted
        }

        let input = try AVAudioFile(forReading: source)
        let rate = input.processingFormat.sampleRate, channels = input.processingFormat.channelCount
        var settings: [String: Any] = [AVSampleRateKey: rate, AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 16]
        switch format {
        case .flac:
            settings[AVFormatIDKey] = kAudioFormatFLAC
        default:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = format == .aiff
        }

        let destination = try AVAudioFile(forWriting: output, settings: settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 65_536) else {
            throw ShiftioError.writeFailed(output)
        }
        while input.framePosition < input.length {
            try input.read(into: buffer)
            try destination.write(from: buffer)
        }
    }
}
