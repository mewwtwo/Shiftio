import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// How hard a file is squeezed. A level sets the detailed values below it; changing one of those by hand makes it Custom.
enum CompressLevel: String, CaseIterable, Identifiable {
    case light, balanced, strong, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .light: String(localized: "compress.light", defaultValue: "Light")
        case .balanced: String(localized: "Balanced")
        case .strong: String(localized: "Strong")
        case .custom: String(localized: "Custom")
        }
    }
    static let presets: [CompressLevel] = [.light, .balanced, .strong]
}

enum CompressKind: String, CaseIterable, Identifiable {
    case image, pdf, audio, video
    var id: String { rawValue }

    var title: String {
        switch self {
        case .image: String(localized: "Images")
        case .pdf: "PDF"
        case .audio: String(localized: "Audio")
        case .video: String(localized: "Video")
        }
    }

    var symbol: String {
        switch self {
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .audio: "waveform"
        case .video: "film"
        }
    }

    init?(url: URL) {
        guard let type = UTType.of(url) else { return nil }
        if type.conforms(to: .pdf) { self = .pdf }
        else if type.conforms(to: .image) { self = .image }
        else if type.conforms(to: .movie) { self = .video }
        else if type.conforms(to: .audio) { self = .audio }
        else { return nil }
    }
}

enum ImageTarget: String, Codable, CaseIterable, Identifiable {
    case auto, jpg, heic
    var id: String { rawValue }
    var title: String { self == .auto ? String(localized: "Same") : rawValue.uppercased() }
}

struct ImageCompress: Codable, Equatable, Sendable {
    var target = ImageTarget.auto
    var quality = 0.65
    /// Fraction of the original width and height.
    var scale = 1.0
    var keepMetadata = true

    mutating func apply(_ level: CompressLevel) {
        switch level {
        case .light: quality = 0.85; scale = 1
        case .balanced: quality = 0.65; scale = 1
        case .strong: quality = 0.4; scale = 0.75
        case .custom: break
        }
    }

    var level: CompressLevel {
        CompressLevel.presets.first { var copy = self; copy.apply($0); return copy == self } ?? .custom
    }
}

enum PDFMode: String, Codable, CaseIterable, Identifiable {
    /// Text and vector art stay as they are; the pictures inside are recompressed.
    case optimize
    /// Every page becomes a JPEG picture. Smallest, but text can no longer be selected.
    case flatten
    var id: String { rawValue }
    var title: String { self == .optimize ? String(localized: "Keep Text") : String(localized: "Flatten Pages") }
}

struct PDFCompress: Codable, Equatable, Sendable {
    var mode = PDFMode.optimize
    /// Keep Text: also shrink pictures to screen resolution.
    var screenImages = true
    var dpi = 110.0
    var quality = 0.6
    var grayscale = false

    mutating func apply(_ level: CompressLevel) {
        switch level {
        case .light: mode = .optimize; screenImages = false
        case .balanced: mode = .optimize; screenImages = true
        case .strong: mode = .flatten; dpi = 100; quality = 0.5
        case .custom: break
        }
    }

    var level: CompressLevel {
        CompressLevel.presets.first { var copy = self; copy.apply($0); return copy == self } ?? .custom
    }
}

struct AudioCompress: Codable, Equatable, Sendable {
    var kbps = 128
    /// 0 keeps the original rate.
    var sampleRate = 0
    var mono = false

    static let bitrates = [64, 96, 128, 160, 192, 256]
    static let sampleRates = [0, 44100, 32000, 22050]

    mutating func apply(_ level: CompressLevel) {
        switch level {
        case .light: kbps = 192
        case .balanced: kbps = 128
        case .strong: kbps = 64
        case .custom: break
        }
    }

    var level: CompressLevel {
        CompressLevel.presets.first { var copy = self; copy.apply($0); return copy == self } ?? .custom
    }
}

struct VideoCompress: Codable, Equatable, Sendable {
    enum Codec: String, Codable, CaseIterable, Identifiable {
        case hevc, h264
        var id: String { rawValue }
        var title: String { self == .hevc ? "HEVC" : "H.264" }
    }

    enum Rate: String, Codable, CaseIterable, Identifiable {
        case quality, bitrate, size
        var id: String { rawValue }
        var title: String {
            switch self {
            case .quality: String(localized: "Quality")
            case .bitrate: String(localized: "Bitrate")
            case .size: String(localized: "File Size")
            }
        }
    }

    var scale = 1.0
    var codec = Codec.hevc
    var rate = Rate.quality
    /// 0…1, mapped to bits per pixel.
    var quality = 0.5
    var mbps = 4.0
    var targetMB = 20.0
    /// 0 keeps the original frame rate.
    var maxFPS = 0
    /// 0 removes the sound.
    var audioKbps = 128

    static let frameRates = [0, 30, 24, 15]
    static let audioBitrates = [0, 64, 96, 128, 192]

    mutating func apply(_ level: CompressLevel) {
        switch level {
        case .light: rate = .quality; quality = 0.75; scale = 1
        case .balanced: rate = .quality; quality = 0.5; scale = 1
        case .strong: rate = .quality; quality = 0.25; scale = 0.5
        case .custom: break
        }
    }

    var level: CompressLevel {
        CompressLevel.presets.first { var copy = self; copy.apply($0); return copy == self } ?? .custom
    }

    /// Scaled size, rounded to even numbers like encoders want.
    func outputSize(of size: CGSize) -> CGSize {
        func even(_ value: CGFloat) -> CGFloat { max(2, (value * scale / 2).rounded() * 2) }
        return scale >= 0.999 ? CGSize(width: max(2, (size.width / 2).rounded() * 2), height: max(2, (size.height / 2).rounded() * 2))
                              : CGSize(width: even(size.width), height: even(size.height))
    }

    func outputFPS(source: Double) -> Double { maxFPS > 0 ? min(Double(maxFPS), source) : source }

    func videoBitrate(size: CGSize, fps: Double, duration: Double) -> Int {
        let audio = Double(audioKbps * 1000)
        var bps: Double
        switch rate {
        case .quality:
            // 0.03 to 0.24 bits per pixel; HEVC gets the same look for about a third less.
            let perPixel = 0.03 * pow(8, quality) * (codec == .hevc ? 0.65 : 1)
            bps = Double(size.width * size.height) * fps * perPixel
        case .bitrate:
            bps = mbps * 1_000_000
        case .size:
            bps = targetMB * 8_000_000 / max(duration, 0.1) - audio
        }
        return Int(max(100_000, bps))
    }

    func estimatedBytes(size: CGSize, fps: Double, duration: Double) -> Int64 {
        let total = Double(videoBitrate(size: size, fps: fps, duration: duration) + audioKbps * 1000)
        return Int64(total * duration / 8)
    }
}

/// Everything the Compress window offers; the last values are remembered.
struct CompressSettings: Codable, Equatable, Sendable {
    var image = ImageCompress()
    var pdf = PDFCompress()
    var audio = AudioCompress()
    var video = VideoCompress()

    private static let key = "compressSettings"

    static func load() -> CompressSettings {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(CompressSettings.self, from: $0) } ?? CompressSettings()
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}
