import AVFoundation

/// Re-encodes a video (with its sound) or audio alone with explicit bit rates, which the export presets can't do.
final class Transcoder: @unchecked Sendable {
    struct VideoPlan: Sendable {
        var size: CGSize
        var codec: VideoCompress.Codec
        var bitrate: Int
        var fps: Double
        var sourceFPS: Double
    }

    struct AudioPlan: Sendable {
        var kbps: Int
        /// 0 keeps the source's rate.
        var sampleRate: Int
        var mono: Bool
    }

    private let lock = NSLock()
    private var cancelled = false
    private var job: Job?

    func cancel() {
        lock.lock()
        cancelled = true
        let job = job
        lock.unlock()
        job?.cancel()
    }

    /// Remembers the running job so `cancel` can reach it. True when cancel was already asked for.
    private func register(_ job: Job) -> Bool {
        lock.withLock {
            self.job = job
            return cancelled
        }
    }

    /// `plans` sees the source's size, frame rate and duration, so the caller can derive a bit rate from them.
    func run(_ source: URL, to output: URL, hasVideo: Bool, audioKbps: Int,
             plans: @Sendable (_ naturalSize: CGSize, _ fps: Double, _ duration: Double) -> (VideoPlan?, AudioPlan?),
             progress: @escaping @Sendable (Double) -> Void) async throws {
        // Leftovers of an earlier run that was killed under this very name.
        OutputNamer.removePartials(of: output)
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        let videoTrack = hasVideo ? try await asset.loadTracks(withMediaType: .video).first : nil
        if hasVideo, videoTrack == nil { throw ShiftioError.unreadable(source) }
        let audioTrack = audioKbps > 0 ? try await asset.loadTracks(withMediaType: .audio).first : nil

        var natural = CGSize(width: 2, height: 2), fps = 30.0
        var transform = CGAffineTransform.identity
        if let videoTrack {
            let loaded = try await videoTrack.load(.naturalSize, .preferredTransform, .nominalFrameRate)
            natural = loaded.0
            transform = loaded.1
            fps = loaded.2 > 0 ? Double(loaded.2) : 30
        }
        var source = (rate: 44100.0, channels: 2)
        if let audioTrack, let description = try await audioTrack.load(.formatDescriptions).first,
           let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
            source = (basic.mSampleRate > 0 ? basic.mSampleRate : 44100, Int(max(1, basic.mChannelsPerFrame)))
        }
        let (videoPlan, audioPlan) = plans(natural, fps, duration)

        let job = try Job(asset: asset, output: output, duration: duration, progress: progress,
                          video: videoTrack.flatMap { track in videoPlan.map { (track, transform, $0) } },
                          audio: audioTrack.flatMap { track in audioPlan.map { (track, $0, source.rate, source.channels) } })
        if register(job) { throw CancellationError() }

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                job.start { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
            OutputNamer.removePartials(of: output)
        } catch {
            try? FileManager.default.removeItem(at: output)
            OutputNamer.removePartials(of: output)
            throw error
        }
    }
}

private final class Job: @unchecked Sendable {
    private struct Pump {
        let output: AVAssetReaderOutput
        let input: AVAssetWriterInput
        let isVideo: Bool
        let reportsProgress: Bool
    }

    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private let outputURL: URL
    private let duration: Double
    private let progress: @Sendable (Double) -> Void
    private let queue = DispatchQueue(label: "app.shiftio.transcode")
    private var pumps: [Pump] = []
    /// Frames closer together than this are dropped, to lower the frame rate.
    private var minimumGap = 0.0
    private var lastKept = -Double.infinity

    private let lock = NSLock()
    private var cancelled = false

    init(asset: AVAsset, output: URL, duration: Double, progress: @escaping @Sendable (Double) -> Void,
         video: (AVAssetTrack, CGAffineTransform, Transcoder.VideoPlan)?,
         audio: (AVAssetTrack, Transcoder.AudioPlan, Double, Int)?) throws {
        reader = try AVAssetReader(asset: asset)
        let isAudioOnly = video == nil
        writer = try AVAssetWriter(outputURL: output, fileType: isAudioOnly ? .m4a : .mp4)
        outputURL = output
        self.duration = max(duration, 0.001)
        self.progress = progress

        if let (track, transform, plan) = video {
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            ])
            out.alwaysCopiesSampleData = false
            guard reader.canAdd(out) else { throw ShiftioError.unreadable(output) }
            reader.add(out)

            var properties: [String: Any] = [
                AVVideoAverageBitRateKey: plan.bitrate,
                AVVideoExpectedSourceFrameRateKey: plan.fps,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
            ]
            if plan.codec == .h264 { properties[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: plan.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
                AVVideoWidthKey: Int(plan.size.width),
                AVVideoHeightKey: Int(plan.size.height),
                AVVideoCompressionPropertiesKey: properties,
            ])
            input.transform = transform
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw ShiftioError.writeFailed(output) }
            writer.add(input)
            pumps.append(Pump(output: out, input: input, isVideo: true, reportsProgress: true))
            if plan.fps < plan.sourceFPS - 0.5 { minimumGap = 0.95 / plan.fps }
        }

        if let (track, plan, sourceRate, sourceChannels) = audio {
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            out.alwaysCopiesSampleData = false
            guard reader.canAdd(out) else { throw ShiftioError.unreadable(output) }
            reader.add(out)

            let channels = plan.mono ? 1 : min(2, sourceChannels)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: channels,
                AVSampleRateKey: plan.sampleRate > 0 ? Double(plan.sampleRate) : min(sourceRate, 48000),
                AVEncoderBitRateKey: plan.kbps * 1000,
            ])
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw ShiftioError.writeFailed(output) }
            writer.add(input)
            pumps.append(Pump(output: out, input: input, isVideo: false, reportsProgress: isAudioOnly))
        }
        if pumps.isEmpty { throw ShiftioError.emptyResult(String(localized: "nothing to encode")) }
        writer.shouldOptimizeForNetworkUse = true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func start(completion: @escaping @Sendable (Error?) -> Void) {
        guard reader.startReading() else { return completion(reader.error ?? ShiftioError.unreadable(outputURL)) }
        guard writer.startWriting() else {
            reader.cancelReading()
            return completion(writer.error ?? ShiftioError.writeFailed(outputURL))
        }
        writer.startSession(atSourceTime: .zero)

        let group = DispatchGroup()
        for pump in pumps {
            group.enter()
            pump.input.requestMediaDataWhenReady(on: queue) { [self] in drain(pump, group) }
        }
        group.notify(queue: queue) { [self] in finish(completion) }
    }

    private func drain(_ pump: Pump, _ group: DispatchGroup) {
        while pump.input.isReadyForMoreMediaData {
            guard !isCancelled, let buffer = pump.output.copyNextSampleBuffer() else {
                pump.input.markAsFinished()
                group.leave()
                return
            }
            let time = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            if pump.isVideo {
                if minimumGap > 0, time - lastKept < minimumGap { continue }
                lastKept = time
            }
            guard pump.input.append(buffer) else {
                pump.input.markAsFinished()
                group.leave()
                return
            }
            if pump.reportsProgress { progress(min(1, max(0, time / duration))) }
        }
    }

    private func finish(_ completion: @escaping @Sendable (Error?) -> Void) {
        if isCancelled {
            reader.cancelReading()
            writer.cancelWriting()
            return completion(CancellationError())
        }
        if reader.status == .failed {
            writer.cancelWriting()
            return completion(reader.error ?? ShiftioError.unreadable(outputURL))
        }
        writer.finishWriting { [self] in
            completion(writer.status == .completed ? nil : (writer.error ?? ShiftioError.writeFailed(outputURL)))
        }
    }
}
