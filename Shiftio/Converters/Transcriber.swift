import AVFoundation
import CoreMedia
import Foundation
import Speech
import UniformTypeIdentifiers

enum TranscriptFormat: String, Sendable {
    case txt, srt
}

/// On-device speech-to-text for audio and video (SpeechAnalyzer, macOS 26).
struct TranscribeAction: FileAction {
    let format: TranscriptFormat

    var id: String { format == .txt ? "transcribe" : "srt" }
    var title: String { format == .txt ? String(localized: "Transcribe") : String(localized: "Subtitles") }
    var symbol: String? { format == .txt ? "quote.bubble" : "captions.bubble" }
    var inputTypes: [UTType] { [.audiovisualContent] }

    func run(_ urls: [URL], options: ActionOptions) async throws -> [URL] {
        var outputs: [URL] = []
        for url in urls {
            let segments = try await Transcriber.transcribe(url)
            guard !segments.isEmpty else { throw ShiftioError.emptyResult(String(localized: "no speech in \(url.lastPathComponent)")) }
            let text = format == .srt ? Transcriber.srt(segments) : segments.map(\.text).joined(separator: " ")
            let output = OutputNamer.url(for: url, ext: format.rawValue)
            try text.write(to: output, atomically: true, encoding: .utf8)
            outputs.append(output)
        }
        return outputs
    }
}

enum Transcriber {
    struct Segment {
        let text: String
        let start: Double
        let end: Double
    }

    static func transcribe(_ url: URL, locale: Locale = .current) async throws -> [Segment] {
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) ?? Locale(identifier: "en_US")
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        // AVAudioFile can't open most video containers, so pull the audio track out first.
        let audioURL = try await audioOnlyCopy(of: url)
        defer { if audioURL != url { try? FileManager.default.removeItem(at: audioURL) } }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task {
            var segments: [Segment] = []
            for try await result in transcriber.results where result.isFinal {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                segments.append(Segment(text: text, start: result.range.start.seconds, end: result.range.end.seconds))
            }
            return segments
        }

        let file = try AVAudioFile(forReading: audioURL)
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collector.value
    }

    private static func audioOnlyCopy(of url: URL) async throws -> URL {
        if UTType.of(url)?.conforms(to: .audio) == true { return url }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        try await MediaConverter.export(url, to: output, format: .m4a)
        return output
    }

    static func srt(_ segments: [Segment]) -> String {
        func timestamp(_ seconds: Double) -> String {
            let millis = Int((seconds * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d",
                          millis / 3_600_000, millis / 60_000 % 60, millis / 1000 % 60, millis % 1000)
        }
        return segments.enumerated().map { index, segment in
            "\(index + 1)\n\(timestamp(segment.start)) --> \(timestamp(segment.end))\n\(segment.text)\n"
        }.joined(separator: "\n")
    }
}
