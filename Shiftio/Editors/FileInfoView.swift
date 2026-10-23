import AVFoundation
import AppKit
import ImageIO
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// What Finder's Get Info shows, plus what is inside the file: picture, camera and place, length and codecs of a video, pages of a PDF.
struct FileInfoAction: EditorAction {
    var id: String { "info" }
    var title: String { String(localized: "Get Info") }
    var symbol: String? { "info.circle" }
    var inputTypes: [UTType] { [.item] }

    @MainActor
    func present(_ url: URL, tint: Color, complete: @escaping @MainActor (Result<[URL], Error>) -> Void) {
        let model = FileInfoModel(url: url)
        EditorWindowController.shared.present(size: CGSize(width: 480, height: min(720, (NSScreen.main?.visibleFrame.height ?? 800) - 40))) { close in
            FileInfoView(model: model, tint: tint, onClose: close)
        }
    }
}

struct InfoRow: Identifiable {
    let id = UUID()
    let label: String
    let value: String
}

struct InfoSection: Identifiable {
    let id = UUID()
    let title: String
    var rows: [InfoRow]
}

@MainActor @Observable
final class FileInfoModel {
    let url: URL
    private(set) var sections: [InfoSection] = []
    private(set) var icon: NSImage
    private(set) var coordinate: (latitude: Double, longitude: Double)?

    init(url: URL) {
        self.url = url
        icon = NSWorkspace.shared.icon(forFile: url.path)
        sections = [general()]
    }

    func load() async {
        let type = UTType.of(url)
        var more: [InfoSection] = []
        if url.hasDirectoryPath || type?.conforms(to: .folder) == true {
            let (count, bytes) = await Task.detached { Self.measureFolder(self.url) }.value
            sections[0].rows.append(InfoRow(label: String(localized: "Contents"), value: String(localized: "\(count) items, \(Self.size(bytes))")))
        } else if type?.conforms(to: .image) == true {
            more += image()
        } else if type?.conforms(to: .pdf) == true {
            more += pdf()
        } else if type?.conforms(to: .audiovisualContent) == true {
            more += await media()
        }
        sections += more.filter { !$0.rows.isEmpty }
    }

    // MARK: General

    private func general() -> InfoSection {
        let keys: Set<URLResourceKey> = [.localizedNameKey, .localizedTypeDescriptionKey, .fileSizeKey, .totalFileAllocatedSizeKey,
                                         .creationDateKey, .contentModificationDateKey, .contentAccessDateKey, .isDirectoryKey]
        let values = try? url.resourceValues(forKeys: keys)
        var rows: [InfoRow] = [InfoRow(label: String(localized: "Name"), value: values?.localizedName ?? url.lastPathComponent)]
        rows.append(InfoRow(label: String(localized: "Kind"), value: values?.localizedTypeDescription ?? url.pathExtension.uppercased()))
        if values?.isDirectory != true, let bytes = values?.fileSize {
            let exact = bytes.formatted(.number)
            rows.append(InfoRow(label: String(localized: "Size"), value: String(localized: "\(Self.size(Int64(bytes))) (\(exact) bytes)")))
            if let disk = values?.totalFileAllocatedSize { rows.append(InfoRow(label: String(localized: "On disk"), value: Self.size(Int64(disk)))) }
        }
        rows.append(InfoRow(label: String(localized: "Where"), value: url.deletingLastPathComponent().path))
        func date(_ value: Date?) -> String? { value?.formatted(date: .long, time: .shortened) }
        if let created = date(values?.creationDate) { rows.append(InfoRow(label: String(localized: "Created"), value: created)) }
        if let modified = date(values?.contentModificationDate) { rows.append(InfoRow(label: String(localized: "Modified"), value: modified)) }
        if let opened = date(values?.contentAccessDate) { rows.append(InfoRow(label: String(localized: "Last opened"), value: opened)) }
        return InfoSection(title: String(localized: "General"), rows: rows)
    }

    nonisolated private static func measureFolder(_ url: URL) -> (Int, Int64) {
        var count = 0
        var bytes: Int64 = 0
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles])
        while let item = walker?.nextObject() as? URL {
            count += 1
            if let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true {
                bytes += Int64(values.fileSize ?? 0)
            }
        }
        return (count, bytes)
    }

    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    // MARK: Picture

    private func image() -> [InfoSection] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return [] }
        var picture: [InfoRow] = []
        let width = properties[kCGImagePropertyPixelWidth] as? Int, height = properties[kCGImagePropertyPixelHeight] as? Int
        if let width, let height {
            picture.append(InfoRow(label: String(localized: "Dimensions"), value: "\(width) × \(height) px"))
            picture.append(InfoRow(label: String(localized: "Megapixels"), value: String(format: "%.1f MP", Double(width * height) / 1_000_000)))
        }
        if let dpi = properties[kCGImagePropertyDPIWidth] as? Double { picture.append(InfoRow(label: String(localized: "Resolution"), value: "\(Int(dpi.rounded())) dpi")) }
        if let model = properties[kCGImagePropertyColorModel] as? String { picture.append(InfoRow(label: String(localized: "Colour model"), value: model)) }
        if let profile = properties[kCGImagePropertyProfileName] as? String { picture.append(InfoRow(label: String(localized: "Profile"), value: profile)) }
        if let depth = properties[kCGImagePropertyDepth] as? Int { picture.append(InfoRow(label: String(localized: "Bit depth"), value: "\(depth) bit")) }
        if let alpha = properties[kCGImagePropertyHasAlpha] as? Bool { picture.append(InfoRow(label: String(localized: "Transparency"), value: alpha ? String(localized: "Yes") : String(localized: "No"))) }

        var camera: [InfoRow] = []
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let make = tiff[kCGImagePropertyTIFFMake] as? String, model = tiff[kCGImagePropertyTIFFModel] as? String
        let name = [make, model].compactMap { $0 }.joined(separator: " ")
        if !name.isEmpty { camera.append(InfoRow(label: String(localized: "Camera"), value: name)) }
        if let lens = exif[kCGImagePropertyExifLensModel] as? String { camera.append(InfoRow(label: String(localized: "Lens"), value: lens)) }
        if let taken = exif[kCGImagePropertyExifDateTimeOriginal] as? String { camera.append(InfoRow(label: String(localized: "Taken"), value: taken)) }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { camera.append(InfoRow(label: "ISO", value: "\(iso)")) }
        if let time = exif[kCGImagePropertyExifExposureTime] as? Double, time > 0 {
            camera.append(InfoRow(label: String(localized: "Exposure"), value: time < 1 ? "1/\(Int((1 / time).rounded())) s" : "\(time) s"))
        }
        if let aperture = exif[kCGImagePropertyExifFNumber] as? Double { camera.append(InfoRow(label: String(localized: "Aperture"), value: String(format: "ƒ/%.1f", aperture))) }
        if let focal = exif[kCGImagePropertyExifFocalLength] as? Double { camera.append(InfoRow(label: String(localized: "Focal length"), value: "\(Int(focal.rounded())) mm")) }

        var place: [InfoRow] = []
        if let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           var latitude = gps[kCGImagePropertyGPSLatitude] as? Double, var longitude = gps[kCGImagePropertyGPSLongitude] as? Double {
            if (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" { latitude = -latitude }
            if (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" { longitude = -longitude }
            coordinate = (latitude, longitude)
            place.append(InfoRow(label: String(localized: "Location"), value: String(format: "%.5f, %.5f", latitude, longitude)))
            if let altitude = gps[kCGImagePropertyGPSAltitude] as? Double { place.append(InfoRow(label: String(localized: "Altitude"), value: "\(Int(altitude.rounded())) m")) }
        }
        return [InfoSection(title: String(localized: "Picture"), rows: picture), InfoSection(title: String(localized: "Camera"), rows: camera), InfoSection(title: String(localized: "Place"), rows: place)]
    }

    // MARK: PDF

    private func pdf() -> [InfoSection] {
        guard let document = PDFDocument(url: url) else { return [] }
        var rows = [InfoRow(label: String(localized: "Pages"), value: "\(document.pageCount)")]
        if let page = document.page(at: 0) {
            let box = page.bounds(for: .mediaBox)
            let inches = (box.width / 72, box.height / 72)
            rows.append(InfoRow(label: String(localized: "Page size"), value: String(format: String(localized: "%.1f × %.1f in (%d × %d mm)"), inches.0, inches.1,
                                                                   Int((inches.0 * 25.4).rounded()), Int((inches.1 * 25.4).rounded()))))
        }
        rows.append(InfoRow(label: String(localized: "Version"), value: "\(document.majorVersion).\(document.minorVersion)"))
        let attributes = document.documentAttributes ?? [:]
        for (label, key) in [(String(localized: "Title"), PDFDocumentAttribute.titleAttribute), (String(localized: "Author"), .authorAttribute), (String(localized: "Subject"), .subjectAttribute),
                             (String(localized: "Creator"), .creatorAttribute), (String(localized: "Producer"), .producerAttribute)] {
            if let value = attributes[key] as? String, !value.isEmpty { rows.append(InfoRow(label: label, value: value)) }
        }
        rows.append(InfoRow(label: String(localized: "Protected"), value: document.isEncrypted ? String(localized: "Yes") : String(localized: "No")))
        rows.append(InfoRow(label: String(localized: "Copying allowed"), value: document.allowsCopying ? String(localized: "Yes") : String(localized: "No")))
        return [InfoSection(title: String(localized: "Document"), rows: rows)]
    }

    // MARK: Audio and video

    private func media() async -> [InfoSection] {
        let asset = AVURLAsset(url: url)
        var general: [InfoRow] = []
        if let duration = try? await asset.load(.duration), duration.isNumeric {
            let seconds = Int(duration.seconds.rounded())
            general.append(InfoRow(label: String(localized: "Duration"), value: String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)))
            if let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, duration.seconds > 0 {
                general.append(InfoRow(label: String(localized: "Overall bitrate"), value: Self.rate(Double(bytes) * 8 / duration.seconds)))
            }
        }
        var video: [InfoRow] = []
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let (size, transform, fps, rate, formats) = try? await track.load(.naturalSize, .preferredTransform, .nominalFrameRate, .estimatedDataRate, .formatDescriptions) {
            let shown = CGRect(origin: .zero, size: size).applying(transform).size
            video.append(InfoRow(label: String(localized: "Dimensions"), value: "\(Int(abs(shown.width))) × \(Int(abs(shown.height))) px"))
            if fps > 0 { video.append(InfoRow(label: String(localized: "Frame rate"), value: String(format: "%g fps", (Double(fps) * 100).rounded() / 100))) }
            if let format = formats.first { video.append(InfoRow(label: String(localized: "Codec"), value: Self.codec(CMFormatDescriptionGetMediaSubType(format)))) }
            if rate > 0 { video.append(InfoRow(label: String(localized: "Bitrate"), value: Self.rate(Double(rate)))) }
        }
        var audio: [InfoRow] = []
        if let track = try? await asset.loadTracks(withMediaType: .audio).first,
           let (rate, formats) = try? await track.load(.estimatedDataRate, .formatDescriptions) {
            if let format = formats.first {
                audio.append(InfoRow(label: String(localized: "Codec"), value: Self.codec(CMFormatDescriptionGetMediaSubType(format))))
                if let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
                    audio.append(InfoRow(label: String(localized: "Sample rate"), value: String(format: "%g kHz", description.mSampleRate / 1000)))
                    audio.append(InfoRow(label: String(localized: "Channels"), value: description.mChannelsPerFrame == 1 ? String(localized: "Mono") : description.mChannelsPerFrame == 2 ? String(localized: "Stereo") : "\(description.mChannelsPerFrame)"))
                }
            }
            if rate > 0 { audio.append(InfoRow(label: String(localized: "Bitrate"), value: Self.rate(Double(rate)))) }
        }
        return [InfoSection(title: String(localized: "Media"), rows: general), InfoSection(title: String(localized: "Video"), rows: video), InfoSection(title: String(localized: "Audio"), rows: audio)]
    }

    private static func rate(_ bitsPerSecond: Double) -> String {
        bitsPerSecond >= 1_000_000 ? String(format: "%.1f Mbps", bitsPerSecond / 1_000_000) : "\(Int((bitsPerSecond / 1000).rounded())) kbps"
    }

    private static func codec(_ type: FourCharCode) -> String {
        let code = String(format: "%c%c%c%c", (type >> 24) & 255, (type >> 16) & 255, (type >> 8) & 255, type & 255)
        let known = ["avc1": "H.264", "hvc1": "HEVC", "hev1": "HEVC", "mp4a": "AAC", "aac ": "AAC", "ap4h": "ProRes 4444", "apch": "ProRes 422 HQ",
                     "apcn": "ProRes 422", "apcs": "ProRes 422 LT", "av01": "AV1", "alac": "Apple Lossless", ".mp3": "MP3", "ac-3": "Dolby Digital",
                     "ec-3": "Dolby Digital Plus", "lpcm": "PCM", "flac": "FLAC", "jpeg": "Motion JPEG"]
        return known[code] ?? code.trimmingCharacters(in: .whitespaces)
    }

    func reveal() { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    func openInMaps() {
        guard let coordinate, let link = URL(string: "https://maps.apple.com/?ll=\(coordinate.latitude),\(coordinate.longitude)&q=Photo") else { return }
        NSWorkspace.shared.open(link)
    }
}

struct FileInfoView: View {
    let model: FileInfoModel
    let tint: Color
    let onClose: () -> Void
    @State private var copied = false

    var body: some View {
        EditorChrome(title: "Get Info", tint: tint, onClose: onClose) {
            VStack(spacing: 12) {
                HStack(spacing: 14) {
                    Image(nsImage: model.icon).resizable().frame(width: 52, height: 52)
                    Text(model.url.lastPathComponent).font(.headline).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 24)

                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(model.sections) { section in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(section.title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                                ForEach(section.rows) { row in
                                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                                        Text(row.label).foregroundStyle(.secondary).frame(width: 118, alignment: .leading)
                                        Text(row.value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .font(.callout)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(.black.opacity(0.07), in: .rect(cornerRadius: 18, style: .continuous))
                        }
                    }
                    .padding(.horizontal, 24)
                }
                .scrollIndicators(.hidden)
                .defaultScrollAnchor(.top)
            }
        } footer: {
            HStack(spacing: 8) {
                Button { model.reveal() } label: { Label("Show in Finder", systemImage: "folder") }.buttonStyle(.glass)
                Button {
                    model.copyPath()
                    copied = true
                } label: { Label(copied ? "Copied" : "Copy Path", systemImage: copied ? "checkmark" : "doc.on.doc") }
                    .buttonStyle(.glass)
                if model.coordinate != nil {
                    Button { model.openInMaps() } label: { Label("Maps", systemImage: "map") }.buttonStyle(.glass)
                }
                Spacer()
                Button("Done", action: onClose).buttonStyle(.glassProminent).tint(tint).keyboardShortcut(.defaultAction)
            }
        }
        .task { await model.load() }
    }
}
