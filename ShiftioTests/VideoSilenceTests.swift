import AVFoundation
import Testing
@testable import Shiftio

struct VideoSilenceTests {
    /// 1 s of tone, 2 s of silence, 1 s of tone.
    private func makeClip() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
        // The file is only complete once it is released, hence the scope.
        do {
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32000)!
        buffer.frameLength = 32000
        for frame in 0..<32000 where frame < 8000 || frame >= 24000 {
            buffer.floatChannelData![0][frame] = 0.5 * sin(Float(frame) * 0.3)
        }
        try file.write(from: buffer)
        }
        return url
    }

    @Test func findsThePauseAndKeepsPadding() async throws {
        let url = try makeClip()
        defer { try? FileManager.default.removeItem(at: url) }
        let found = await VideoSilence.ranges(in: url, within: 0..<4)
        #expect(found.count == 1)
        let pause = try #require(found.first)
        #expect(abs(pause.lowerBound - 1.15) < 0.05)
        #expect(abs(pause.upperBound - 2.85) < 0.05)
    }
}
