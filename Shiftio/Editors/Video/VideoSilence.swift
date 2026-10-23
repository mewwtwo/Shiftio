import AVFoundation

/// Finds the quiet stretches of a clip's sound.
enum VideoSilence {
    /// Level under which a 20 ms window counts as quiet.
    static let threshold: Float = 0.01 // about -40 dB
    /// Shortest pause worth cutting.
    static let minimumLength = 0.6
    /// Kept on each side of a pause so words do not start or end abruptly.
    static let padding = 0.15

    /// The quiet pieces inside `range`, already shortened by the padding. Empty when there is no sound.
    static func ranges(in url: URL, within range: Range<Double>) async -> [Range<Double>] {
        await Task.detached(priority: .userInitiated) { scan(url, within: range) }.value
    }

    private static func scan(_ url: URL, within range: Range<Double>) -> [Range<Double>] {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return [] }
        let rate = 8000.0
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.timeRange = CMTimeRange(start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
                                       end: CMTime(seconds: range.upperBound, preferredTimescale: 600))
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }

        let window = Int(rate * 0.02)
        var energy: Float = 0, filled = 0
        var quietFrom: Double?
        var found: [Range<Double>] = []
        var index = 0 // windows seen so far

        func close(at time: Double) {
            guard let from = quietFrom else { return }
            quietFrom = nil
            if time - from >= minimumLength {
                let padded = (from + padding)..<(time - padding)
                if padded.upperBound > padded.lowerBound { found.append(padded) }
            }
        }

        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var data = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            let status = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            guard status == kCMBlockBufferNoErr else { continue }
            for sample in data {
                energy += sample * sample
                filled += 1
                guard filled == window else { continue }
                let time = range.lowerBound + Double(index * window) / rate
                if (energy / Float(window)).squareRoot() < threshold {
                    if quietFrom == nil { quietFrom = time }
                } else {
                    close(at: time)
                }
                energy = 0
                filled = 0
                index += 1
            }
        }
        close(at: range.lowerBound + Double(index * window) / rate)
        return found
    }
}
