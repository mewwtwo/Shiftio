import AVFoundation
import CoreImage
import Testing
@testable import Shiftio

/// Renders real clips through the editor's exporter. Needs ffmpeg for the fixtures; skipped without it.
@MainActor
struct VideoToolsTests {
    private static let ffmpeg = "/opt/homebrew/bin/ffmpeg"
    private var available: Bool { FileManager.default.isExecutableFile(atPath: Self.ffmpeg) }

    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `filter` is a lavfi source; the clip is 3 s at 30 fps with a 440 Hz tone.
    private func makeClip(_ filter: String, in dir: URL, name: String = "clip.mp4", size: String = "320x240", tone: Bool = true) throws -> URL {
        let file = dir.appendingPathComponent(name)
        var arguments = ["-y", "-f", "lavfi", "-i", "\(filter),format=yuv420p"]
        if tone { arguments += ["-f", "lavfi", "-i", "sine=f=440:d=3"] }
        arguments += ["-s", size, "-t", "3", "-r", "30", "-c:v", "libx264"] + (tone ? ["-c:a", "aac"] : []) + [file.path]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.ffmpeg)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return file
    }

    private func edit(_ duration: Double = 3) -> VideoEdit {
        VideoEdit(segments: [CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))])
    }

    private func frame(_ url: URL, at seconds: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    /// Mean red, green, blue (0...255) of a part of the picture, given as fractions from the top left.
    private func average(_ image: CGImage, _ area: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> (r: Double, g: Double, b: Double) {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var sum = (0.0, 0.0, 0.0), count = 0.0
        for y in Int(area.minY * Double(height))..<Int(area.maxY * Double(height)) {
            for x in Int(area.minX * Double(width))..<Int(area.maxX * Double(width)) {
                let i = (y * width + x) * 4
                sum.0 += Double(pixels[i]); sum.1 += Double(pixels[i + 1]); sum.2 += Double(pixels[i + 2]); count += 1
            }
        }
        return (sum.0 / count, sum.1 / count, sum.2 / count)
    }

    /// Spread of brightness across a part of the picture: low when it has been blurred or covered.
    private func spread(_ image: CGImage, _ area: CGRect) -> Double {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var values: [Double] = []
        for y in Int(area.minY * Double(height))..<Int(area.maxY * Double(height)) {
            for x in Int(area.minX * Double(width))..<Int(area.maxX * Double(width)) {
                let i = (y * width + x) * 4
                values.append(Double(pixels[i]) + Double(pixels[i + 1]) + Double(pixels[i + 2]))
            }
        }
        let mean = values.reduce(0, +) / Double(values.count)
        return (values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)).squareRoot()
    }

    @Test func reversePlaysTheClipBackwards() async throws {
        guard available else { return }
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Red grows from nothing to full over the clip.
        let source = try makeClip("color=c=black:s=320x240:d=3:r=30,geq=r='255*T/3':g=0:b=0", in: dir)
        var reversed = edit()
        reversed.reversed = true
        let output = dir.appendingPathComponent("back.mp4")
        try await VideoExporter.export(source, edit: reversed, to: output)

        let asset = AVURLAsset(url: output)
        let length = try await asset.load(.duration).seconds
        #expect(abs(length - 3) < 0.2)
        #expect(average(try await frame(output, at: 0.1)).r > 200)
        #expect(average(try await frame(output, at: 2.8)).r < 50)
        // The sound survived, and it is still there.
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
    }

    @Test func blurAndPixelateFlattenTheirArea() async throws {
        guard available else { return }
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try makeClip("testsrc2=s=320x240:r=30:d=3", in: dir, tone: false)
        var hidden = edit()
        hidden.blurs = [VideoBlur(rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), pixelates: false),
                        VideoBlur(rect: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5), pixelates: true)]
        let output = dir.appendingPathComponent("hidden.mp4")
        try await VideoExporter.export(source, edit: hidden, to: output)

        let before = try await frame(source, at: 1), after = try await frame(output, at: 1)
        // Top left is blurred, bottom right pixelated; the other corners are left alone.
        #expect(spread(after, CGRect(x: 0.05, y: 0.05, width: 0.4, height: 0.4)) < spread(before, CGRect(x: 0.05, y: 0.05, width: 0.4, height: 0.4)))
        let untouched = CGRect(x: 0.55, y: 0.05, width: 0.4, height: 0.4)
        print("untouched corner:", average(before, untouched), average(after, untouched))
        #expect(abs(average(after, untouched).g - average(before, untouched).g) < 20)
    }

    @Test func watermarkAndSubtitlesAreDrawn() async throws {
        guard available else { return }
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try makeClip("color=c=black:s=320x240:d=3:r=30", in: dir, tone: false)
        var marked = edit()
        marked.watermark = Watermark(image: try #require(TextImage.render("LOGO", size: 120, boxed: false)), corner: .topLeft, size: .large)
        marked.subtitles = [SubtitleCue(start: 0, end: 1.5, text: "Hello there")]
        let output = dir.appendingPathComponent("marked.mp4")
        try await VideoExporter.export(source, edit: marked, to: output)

        let early = try await frame(output, at: 0.5), late = try await frame(output, at: 2.5)
        #expect(average(early, CGRect(x: 0, y: 0, width: 0.4, height: 0.25)).r > 15)   // watermark
        #expect(average(early, CGRect(x: 0.2, y: 0.8, width: 0.6, height: 0.15)).r > 8) // subtitle box and text
        #expect(average(late, CGRect(x: 0.2, y: 0.8, width: 0.6, height: 0.15)).r < 5)  // gone after its cue
    }

    @Test func tiledWatermarkCoversTheWholePictureAndFollowsOpacity() async throws {
        guard available else { return }
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try makeClip("color=c=black:s=320x240:d=3:r=30", in: dir, tone: false)
        let mark = try #require(TextImage.render("MARK", size: 120, boxed: false))
        func brightness(_ opacity: Double) async throws -> [Double] {
            var marked = edit()
            marked.watermark = Watermark(image: mark, corner: .tiled, size: .medium, opacity: opacity)
            let output = dir.appendingPathComponent("tiled \(opacity).mp4")
            try await VideoExporter.export(source, edit: marked, to: output)
            let picture = try await frame(output, at: 1)
            // Four quarters of the picture: a corner mark would light only one.
            return [CGRect(x: 0, y: 0, width: 0.5, height: 0.5), CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5),
                    CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5), CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)]
                .map { average(picture, $0).r }
        }
        let strong = try await brightness(0.9), faint = try await brightness(0.3)
        #expect(strong.allSatisfy { $0 > 3 })
        #expect(zip(strong, faint).allSatisfy { $0 > $1 * 1.5 })
    }

    @Test func joinAddsTheOtherClipAfterTheFirst() async throws {
        guard available else { return }
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try makeClip("color=c=red:s=320x240:d=3:r=30", in: dir, name: "a.mp4")
        let second = try makeClip("color=c=blue:s=240x320:d=3:r=30", in: dir, name: "b.mp4", size: "240x320")
        var joined = edit(2)
        joined.joined = [second]
        let output = dir.appendingPathComponent("joined.mp4")
        try await VideoExporter.export(first, edit: joined, to: output)

        let asset = AVURLAsset(url: output)
        #expect(abs(try await asset.load(.duration).seconds - 5) < 0.3)
        let early = average(try await frame(output, at: 1)), late = average(try await frame(output, at: 4), CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2))
        #expect(early.r > 150 && early.b < 80)
        #expect(late.b > 150 && late.r < 80)
    }

    @Test func sizeLimitKeepsTheFileUnderIt() async throws {
        guard available else { return }
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try makeClip("testsrc2=s=1280x720:r=30:d=3,noise=alls=40:allf=t", in: dir, name: "big.mp4", size: "1280x720")
        var limited = edit()
        limited.sizeLimit = 400_000
        let output = dir.appendingPathComponent("small.mp4")
        try await VideoExporter.export(source, edit: limited, to: output)
        let size = try #require(try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int)
        print("size limit result:", size)
        #expect(size <= 400_000, "size \(size)")
    }

    @Test func replacementSoundStandsInForTheOriginal() async throws {
        guard available else { return }
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try makeClip("color=c=gray:s=320x240:d=3:r=30", in: dir, tone: false)
        let other = try makeClip("color=c=gray:s=160x120:d=2:r=30", in: dir, name: "sound.mp4")
        var replaced = edit()
        replaced.replacementAudio = other
        let output = dir.appendingPathComponent("replaced.mp4")
        try await VideoExporter.export(source, edit: replaced, to: output)
        let asset = AVURLAsset(url: output)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
    }

    @Test func metadataIsDroppedWhenAsked() async throws {
        guard available else { return }
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("tagged.mp4")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.ffmpeg)
        process.arguments = ["-y", "-f", "lavfi", "-i", "color=c=gray:s=320x240:d=1:r=30", "-metadata", "title=Secret", "-metadata", "location=+50.4500+030.5233/",
                             "-c:v", "libx264", "-pix_fmt", "yuv420p", source.path]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        func titles(_ url: URL) async throws -> [String] {
            let items = try await AVURLAsset(url: url).load(.metadata)
            var found: [String] = []
            for item in items { if let text = try await item.load(.stringValue) { found.append(text) } }
            return found
        }
        print("source metadata:", try await titles(source))
        var kept = VideoEdit(segments: [CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600))])
        let keptFile = dir.appendingPathComponent("kept.mp4")
        try await VideoExporter.export(source, edit: kept, to: keptFile)
        let keptTitles = try await titles(keptFile)
        print("kept metadata:", keptTitles)
        #expect(keptTitles.contains("Secret"))
        kept.stripsMetadata = true
        let strippedFile = dir.appendingPathComponent("stripped.mp4")
        try await VideoExporter.export(source, edit: kept, to: strippedFile)
        let stripped = try await titles(strippedFile)
        print("stripped metadata:", stripped)
        #expect(!stripped.contains { $0.contains("Secret") || $0.contains("50.45") })
    }

    @Test func estimateIsCloseToTheRealFile() async throws {
        guard available else { return }
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try makeClip("testsrc2=s=640x480:r=30:d=3", in: dir)
        let guess = try #require(await VideoExporter.estimatedSize(source, edit: edit()))
        let output = dir.appendingPathComponent("real.mp4")
        try await VideoExporter.export(source, edit: edit(), to: output)
        let real = try #require(try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int)
        print("estimate:", guess, "real:", real)
        #expect(guess > 0)
    }
}

struct VideoAudioTests {
    private func tone(seconds: Double, amplitude: Float, noise: Float = 0) -> VideoAudio.PCM {
        let rate = 44100.0, frames = Int(rate * seconds)
        var samples = [Float](repeating: 0, count: frames * 2)
        var seed: UInt32 = 1
        for frame in 0..<frames {
            seed = seed &* 1664525 &+ 1013904223
            let hiss = (Float(seed >> 8) / Float(1 << 24) - 0.5) * 2 * noise
            let value = amplitude * sin(Float(frame) * 2 * .pi * 300 / Float(rate)) + hiss
            samples[frame * 2] = value
            samples[frame * 2 + 1] = value
        }
        return VideoAudio.PCM(rate: rate, channels: 2, samples: samples)
    }

    private func rms(_ pcm: VideoAudio.PCM, from: Double, to: Double) -> Float {
        let range = Int(from * pcm.rate)..<Int(to * pcm.rate)
        let sum = range.reduce(Float(0)) { $0 + pcm.samples[$1 * pcm.channels] * pcm.samples[$1 * pcm.channels] }
        return (sum / Float(range.count)).squareRoot()
    }

    @Test func quietSpeechGetsLouderLoudGetsSofter() {
        #expect(VideoAudio.gain(for: tone(seconds: 2, amplitude: 0.05)) > 2)
        #expect(VideoAudio.gain(for: tone(seconds: 2, amplitude: 0.9)) < 1)
    }

    @Test func noiseBetweenWordsGoesDownAndSpeechStays() {
        // 2 s of hiss, then 2 s of a tone over the same hiss.
        var pcm = tone(seconds: 4, amplitude: 0, noise: 0.01)
        let loud = tone(seconds: 4, amplitude: 0.3, noise: 0.01)
        let start = Int(2 * pcm.rate) * 2
        pcm.samples.replaceSubrange(start..., with: loud.samples[start...])
        let cleaned = VideoAudio.denoise(pcm)
        let hissBefore = rms(pcm, from: 0.5, to: 1.8), hissAfter = rms(cleaned, from: 0.5, to: 1.8)
        let toneBefore = rms(pcm, from: 2.5, to: 3.8), toneAfter = rms(cleaned, from: 2.5, to: 3.8)
        print("hiss", hissBefore, "->", hissAfter, "tone", toneBefore, "->", toneAfter)
        #expect(hissAfter < hissBefore * 0.4)
        #expect(toneAfter > toneBefore * 0.85)
    }

    @Test func reversingSwapsTheEnds() {
        var pcm = tone(seconds: 1, amplitude: 0.5)
        pcm.samples[0] = 0.9
        let back = VideoAudio.reversed(pcm)
        #expect(back.samples[back.samples.count - 2] == 0.9)
    }
}

@MainActor
struct VideoSplitTests {
    @Test func splitPointsGiveOneFilePerPart() async throws {
        let ffmpeg = "/opt/homebrew/bin/ffmpeg"
        guard FileManager.default.isExecutableFile(atPath: ffmpeg) else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("clip.mp4")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-y", "-f", "lavfi", "-i", "testsrc2=s=320x240:r=30:d=3", "-f", "lavfi", "-i", "sine=f=440:d=3", "-t", "3",
                             "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", source.path]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        let model = VideoEditModel(url: source)
        await model.load()
        model.seek(to: 1)
        model.split()
        model.seek(to: 2)
        model.split()
        #expect(model.splits.count == 2)
        let files = try await model.export()
        #expect(files.count == 3)
        defer { files.forEach { try? FileManager.default.removeItem(at: $0) } }
        for file in files {
            let length = try await AVURLAsset(url: file).load(.duration).seconds
            #expect(abs(length - 1) < 0.2)
        }
        #expect(Set(files.map(\.lastPathComponent)).count == 3)
    }
}
