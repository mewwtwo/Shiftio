import AVFoundation

/// Sound work that needs the samples themselves: loudness, noise reduction and playing backwards.
enum VideoAudio {
    struct PCM: Sendable {
        var rate: Double
        var channels: Int
        /// Interleaved.
        var samples: [Float]
        var frames: Int { channels > 0 ? samples.count / channels : 0 }
    }

    /// The first sound track of `url` as floats. nil when there is none.
    static func read(_ url: URL, rate: Double = 44100, channels: Int = 2) async -> PCM? {
        await Task.detached(priority: .userInitiated) { readNow(url, rate: rate, channels: channels) }.value
    }

    private static func readNow(_ url: URL, rate: Double, channels: Int) -> PCM? {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first, let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let count = length / MemoryLayout<Float>.size
            let start = samples.count
            samples.append(contentsOf: repeatElement(0, count: count))
            let status = samples.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size,
                                           destination: $0.baseAddress!.advanced(by: start * MemoryLayout<Float>.size))
            }
            if status != kCMBlockBufferNoErr { samples.removeLast(count) }
        }
        return samples.isEmpty ? nil : PCM(rate: rate, channels: channels, samples: samples)
    }

    /// Writes uncompressed, which the export then encodes along with the picture.
    static func write(_ pcm: PCM, to url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: pcm.rate, channels: AVAudioChannelCount(pcm.channels), interleaved: false)
        else { throw ShiftioError.writeFailed(url) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let block = 32768
        var position = 0
        while position < pcm.frames {
            let count = min(block, pcm.frames - position)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)), let data = buffer.floatChannelData
            else { throw ShiftioError.writeFailed(url) }
            buffer.frameLength = AVAudioFrameCount(count)
            for channel in 0..<pcm.channels {
                for frame in 0..<count { data[channel][frame] = pcm.samples[(position + frame) * pcm.channels + channel] }
            }
            try file.write(from: buffer)
            position += count
        }
    }

    // MARK: Loudness

    /// How much to multiply the sound by to bring speech to a comfortable level without clipping. 1 when it is already there.
    static func normalizeGain(for url: URL) async -> Double {
        guard let pcm = await read(url, rate: 16000, channels: 1) else { return 1 }
        return gain(for: pcm)
    }

    /// Average level over the stretches that are not quiet, so pauses do not drag the target down.
    static func gain(for pcm: PCM) -> Double {
        let window = max(1, Int(pcm.rate * 0.05))
        var peak: Float = 0
        var sum: Double = 0, windows = 0
        var index = 0
        while index + window <= pcm.samples.count {
            var energy: Float = 0
            for sample in pcm.samples[index..<(index + window)] {
                energy += sample * sample
                peak = max(peak, abs(sample))
            }
            let rms = (energy / Float(window)).squareRoot()
            if rms > 0.003 { // above about -50 dB
                sum += Double(energy) / Double(window)
                windows += 1
            }
            index += window
        }
        guard windows > 0, peak > 0 else { return 1 }
        let rms = (sum / Double(windows)).squareRoot()
        let wanted = 0.125 / rms // about -18 dB
        let safe = 0.89 / Double(peak) // never past -1 dB
        return min(max(min(wanted, safe), 0.25), 6)
    }

    // MARK: Noise

    /// Takes out rumble below 80 Hz, then turns down whatever stays near the room's own level between words.
    /// The threshold is found from the clip itself: the quietest tenth of it is taken to be the noise.
    static func denoise(_ pcm: PCM) -> PCM {
        var pcm = pcm
        let channels = pcm.channels
        highPass(&pcm, cutoff: 80)

        let frames = pcm.frames
        let window = max(1, Int(pcm.rate * 0.02))
        let blocks = frames / window
        guard blocks > 10 else { return pcm }
        var levels = [Float](repeating: 0, count: blocks)
        for block in 0..<blocks {
            var energy: Float = 0
            for frame in (block * window)..<((block + 1) * window) {
                for channel in 0..<channels {
                    let sample = pcm.samples[frame * channels + channel]
                    energy += sample * sample
                }
            }
            levels[block] = (energy / Float(window * channels)).squareRoot()
        }
        let floor = max(levels.sorted()[blocks / 10], 0.0005)
        let threshold = floor * 2.5
        let follow = Float(1 - exp(-1 / (pcm.rate * 0.002)))
        let fall = Float(1 - exp(-1 / (pcm.rate * 0.1)))
        let opening = Float(1 - exp(-1 / (pcm.rate * 0.005)))
        let closing = Float(1 - exp(-1 / (pcm.rate * 0.15)))

        // Louder than the threshold passes untouched; quieter is turned down by 3:1, but never by more than 24 dB.
        var envelope: Float = 0
        var gain: Float = 1
        for frame in 0..<frames {
            var level: Float = 0
            for channel in 0..<channels { level = max(level, abs(pcm.samples[frame * channels + channel])) }
            envelope += (level > envelope ? follow : fall) * (level - envelope)
            let target: Float
            if envelope >= threshold {
                target = 1
            } else {
                target = max(0.063, pow(max(envelope, 1e-5) / threshold, 2))
            }
            gain += (target > gain ? opening : closing) * (target - gain)
            for channel in 0..<channels { pcm.samples[frame * channels + channel] *= gain }
        }
        return pcm
    }

    /// Second-order Butterworth, run forwards over each channel.
    private static func highPass(_ pcm: inout PCM, cutoff: Double) {
        let omega = 2 * Double.pi * cutoff / pcm.rate
        let alpha = sin(omega) / (2 * 0.7071)
        let cosine = cos(omega)
        let a0 = 1 + alpha
        let b0 = Float((1 + cosine) / 2 / a0), b1 = Float(-(1 + cosine) / a0), b2 = b0
        let a1 = Float(-2 * cosine / a0), a2 = Float((1 - alpha) / a0)
        for channel in 0..<pcm.channels {
            var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
            for frame in 0..<pcm.frames {
                let index = frame * pcm.channels + channel
                let x0 = pcm.samples[index]
                let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                pcm.samples[index] = y0
                x2 = x1; x1 = x0; y2 = y1; y1 = y0
            }
        }
    }

    /// The sound of `url` with noise reduced, over the same timeline, as a temporary file. The caller removes it.
    static func denoised(_ url: URL) async throws -> URL {
        guard let pcm = await read(url) else { throw ShiftioError.emptyResult(String(localized: "this video has no sound")) }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        let cleaned = await Task.detached(priority: .userInitiated) { denoise(pcm) }.value
        try write(cleaned, to: output)
        return output
    }

    // MARK: Backwards

    static func reversed(_ pcm: PCM) -> PCM {
        var copy = pcm
        let channels = pcm.channels, frames = pcm.frames
        for frame in 0..<frames {
            for channel in 0..<channels {
                copy.samples[frame * channels + channel] = pcm.samples[(frames - 1 - frame) * channels + channel]
            }
        }
        return copy
    }
}
