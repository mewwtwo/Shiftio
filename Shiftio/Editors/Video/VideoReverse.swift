import AVFoundation

/// Plays a clip backwards. Frames are read a few at a time from the end and written in the opposite order, so a long
/// clip never has to sit in memory whole.
enum VideoReverse {
    /// Memory one batch of frames may take.
    private static let batchBytes = 400_000_000

    /// The picture, reversed, goes to `video` (no sound). The sound, if the clip has any, goes to `audio`; the return value says whether it did.
    static func reverse(_ source: URL, video: URL, audio: URL) async throws -> Bool {
        try await Task.detached(priority: .userInitiated) { try await reverseNow(source, video: video, audio: audio) }.value
    }

    private static func reverseNow(_ source: URL, video output: URL, audio audioOutput: URL) async throws -> Bool {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ShiftioError.unreadable(source) }
        let (size, transform, rate, duration) = try await (track.load(.naturalSize), track.load(.preferredTransform),
                                                          track.load(.nominalFrameRate), asset.load(.duration).seconds)
        let fps = rate > 0 ? Double(rate) : 30
        let frameLength = 1 / fps
        let width = Int(size.width), height = Int(size.height)

        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoQualityKey: 0.85],
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(videoInput) else { throw ShiftioError.writeFailed(output) }
        writer.add(videoInput)
        guard writer.startWriting() else { throw writer.error ?? ShiftioError.writeFailed(output) }
        writer.startSession(atSourceTime: .zero)

        let batch = max(8, min(120, batchBytes / max(1, width * height * 4)))
        let span = Double(batch) * frameLength
        var end = duration
        var written = 0
        while end > 0.0001 {
            let start = max(0, end - span)
            let frames = try readFrames(asset, of: source, track: track, from: start, to: end)
            for frame in frames.reversed() {
                // Mirror each frame's time about the middle of the clip, so uneven frame rates stay uneven.
                let time = max(0, duration - frame.time - frameLength)
                while !videoInput.isReadyForMoreMediaData {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(4))
                }
                guard adaptor.append(frame.buffer, withPresentationTime: CMTime(seconds: time, preferredTimescale: 6000)) else {
                    throw writer.error ?? ShiftioError.writeFailed(output)
                }
                written += 1
            }
            end = start
        }
        videoInput.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed, written > 0 else { throw writer.error ?? ShiftioError.writeFailed(output) }

        guard let sound = await VideoAudio.read(source) else { return false }
        try VideoAudio.write(VideoAudio.reversed(sound), to: audioOutput)
        return true
    }

    private struct Frame {
        let buffer: CVPixelBuffer
        let time: Double
    }

    private static func readFrames(_ asset: AVAsset, of source: URL, track: AVAssetTrack, from start: Double, to end: Double) throws -> [Frame] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 6000), end: CMTime(seconds: end, preferredTimescale: 6000))
        guard reader.canAdd(output) else { throw ShiftioError.unreadable(source) }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ShiftioError.unreadable(source) }
        var frames: [Frame] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            // The reader can hand back the frame just before the range; the batch before this one already has it.
            guard time >= start - 0.0001, time < end - 0.0001 else { continue }
            frames.append(Frame(buffer: buffer, time: time))
        }
        return frames
    }
}
