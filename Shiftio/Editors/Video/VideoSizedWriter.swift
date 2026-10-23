import AVFoundation

/// Writes a video at a bitrate worked out from the size it may take. The system export presets can't be told a size,
/// so frames are read from the edited composition and encoded here.
enum VideoSizedWriter {
    struct Job: @unchecked Sendable {
        let composition: AVAsset
        /// nil when the picture is left as it is.
        let videoComposition: AVVideoComposition?
        let audioMix: AVAudioMix?
        let metadata: [AVMetadataItem]
        let hevc: Bool
        let bytes: Int64
        let seconds: Double
    }

    /// Room kept for the container and for the encoder's own overshoot.
    private static let safety = 0.9
    private static let audioBitrate = 128_000

    /// Encoders overshoot a low bitrate, especially on short or noisy clips, so a file that came out too big is written again
    /// with the bitrate scaled down by how much it missed.
    static func write(_ job: Job, to output: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            var scale = 1.0
            for attempt in 0..<6 {
                try await run(job, to: output, scale: scale)
                let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int64) ?? 0
                guard size > job.bytes, attempt < 5 else { return }
                scale *= Double(job.bytes) / Double(size) * 0.92
                try FileManager.default.removeItem(at: output)
            }
        }.value
    }

    private static func run(_ job: Job, to output: URL, scale: Double) async throws {
        let asset = job.composition
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !videoTracks.isEmpty else { throw ShiftioError.unreadable(output) }
        let picture: AVVideoComposition
        if let given = job.videoComposition {
            picture = given
        } else {
            picture = try await AVVideoComposition.videoComposition(withPropertiesOf: asset)
        }

        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        videoOutput.videoComposition = picture
        guard reader.canAdd(videoOutput) else { throw ShiftioError.unreadable(output) }
        reader.add(videoOutput)
        var audioOutput: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let mixed = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            mixed.audioMix = job.audioMix
            mixed.audioTimePitchAlgorithm = .spectral
            if reader.canAdd(mixed) {
                reader.add(mixed)
                audioOutput = mixed
            }
        }

        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.metadata = job.metadata
        let seconds = max(job.seconds, 0.1)
        let audioShare = audioOutput == nil ? 0 : Double(audioBitrate)
        let videoRate = max(80_000, (Double(job.bytes) * 8 * safety / seconds - audioShare) * scale)
        var compression: [String: Any] = [AVVideoAverageBitRateKey: Int(videoRate)]
        if !job.hevc { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: job.hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: Int(picture.renderSize.width),
            AVVideoHeightKey: Int(picture.renderSize.height),
            AVVideoCompressionPropertiesKey: compression,
        ])
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw ShiftioError.writeFailed(output) }
        writer.add(videoInput)
        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: audioBitrate,
            ])
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        guard reader.startReading() else { throw reader.error ?? ShiftioError.unreadable(output) }
        guard writer.startWriting() else { throw writer.error ?? ShiftioError.writeFailed(output) }
        writer.startSession(atSourceTime: .zero)

        // Both streams are fed in turn, so neither waits long for the other.
        var videoDone = false, audioDone = audioInput == nil
        while !(videoDone && audioDone) {
            try Task.checkCancellation()
            var moved = false
            if !videoDone, videoInput.isReadyForMoreMediaData {
                if let sample = videoOutput.copyNextSampleBuffer() {
                    guard videoInput.append(sample) else { throw writer.error ?? ShiftioError.writeFailed(output) }
                } else {
                    videoInput.markAsFinished()
                    videoDone = true
                }
                moved = true
            }
            if !audioDone, let audioInput, let audioOutput, audioInput.isReadyForMoreMediaData {
                if let sample = audioOutput.copyNextSampleBuffer() {
                    guard audioInput.append(sample) else { throw writer.error ?? ShiftioError.writeFailed(output) }
                } else {
                    audioInput.markAsFinished()
                    audioDone = true
                }
                moved = true
            }
            if !moved { try await Task.sleep(for: .milliseconds(2)) }
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ShiftioError.writeFailed(output) }
    }
}
