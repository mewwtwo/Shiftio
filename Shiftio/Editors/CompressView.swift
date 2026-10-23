import AVFoundation
import SwiftUI

/// What the window knows about the one audio or video file it was opened for, to estimate results and offer sensible choices.
struct CompressMediaInfo {
    var size: CGSize
    var fps: Double
    var duration: Double
}

@MainActor @Observable
final class CompressModel {
    private(set) var files: [URL]
    var settings = CompressSettings.load()
    private(set) var isRunning = false
    private(set) var progress = 0.0
    var message: String?
    private(set) var info: CompressMediaInfo?
    /// Encoded size of the one image, with the current settings.
    private(set) var imageBytes: Int64?
    private var transcoder = Transcoder()

    init(files: [URL]) { self.files = files }

    var kinds: [CompressKind] {
        CompressKind.allCases.filter { kind in files.contains { CompressKind(url: $0) == kind } }
    }

    func files(of kind: CompressKind) -> [URL] { files.filter { CompressKind(url: $0) == kind } }

    func bytes(of kind: CompressKind) -> Int64 {
        files(of: kind).reduce(0) { $0 + Self.bytes(at: $1) }
    }

    static func bytes(at url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    /// Size, frame rate and length of a single audio or video file.
    func loadInfo() async {
        guard files.count == 1, let url = files.first, let kind = CompressKind(url: url), kind == .video || kind == .audio else { return }
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration).seconds
            if kind == .video, let track = try await asset.loadTracks(withMediaType: .video).first {
                let (natural, transform, fps) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
                let oriented = CGRect(origin: .zero, size: natural).applying(transform).size
                info = CompressMediaInfo(size: oriented, fps: fps > 0 ? Double(fps) : 30, duration: duration)
            } else {
                info = CompressMediaInfo(size: .zero, fps: 0, duration: duration)
            }
        } catch {
            info = nil
        }
    }

    /// Runs a trial encode (after a short pause, so dragging a slider doesn't encode on every step).
    func refreshImageEstimate() async {
        guard files.count == 1, let url = files.first, CompressKind(url: url) == .image else { return }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        imageBytes = (try? await Compressor.imageData(url, settings: settings.image))?.data.count.asInt64
    }

    func cancel() { transcoder.cancel() }

    /// Compresses every file. Finished ones leave the list; failed ones stay, with the reason in `message`.
    func run() async -> (sources: [URL], outputs: [URL]) {
        settings.save()
        transcoder = Transcoder()
        let transcoder = transcoder
        isRunning = true
        progress = 0
        message = nil
        defer { isRunning = false }

        var sources: [URL] = [], outputs: [URL] = [], failures: [String] = []
        let total = Double(files.count)
        for (index, url) in files.enumerated() {
            do {
                let output = try await Compressor.compress(url, settings: settings, transcoder: transcoder) { [weak self] fraction in
                    Task { @MainActor in self?.progress = (Double(index) + fraction) / total }
                }
                sources.append(url)
                outputs.append(output)
            } catch is CancellationError {
                break
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
            progress = Double(index + 1) / total
        }
        files.removeAll { sources.contains($0) }
        if !failures.isEmpty { message = failures.joined(separator: "\n") }
        return (sources, outputs)
    }
}

private extension Int {
    var asInt64: Int64 { Int64(self) }
}

struct CompressView: View {
    let model: CompressModel
    let tint: Color
    let onClose: () -> Void
    let onFinish: @MainActor (_ sources: [URL], Result<[URL], Error>) -> Void

    var body: some View {
        @Bindable var model = model
        EditorChrome(title: "Compress", tint: tint, onClose: close) {
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(model.kinds) { kind in section(kind, model: $model.settings) }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 6)
            }
            .scrollIndicators(.hidden)
            .disabled(model.isRunning)
        } footer: {
            HStack(spacing: 12) {
                if model.isRunning {
                    ProgressView(value: model.progress).frame(width: 140)
                } else if let message = model.message {
                    Text(message).font(.callout).foregroundStyle(.red).lineLimit(3)
                } else {
                    Text(model.files.count == 1 ? model.files[0].lastPathComponent : String(localized: "\(model.files.count) files"))
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if model.isRunning {
                    Button("Stop") { model.cancel() }.buttonStyle(.glass)
                } else {
                    Button("Compress") { start() }
                        .buttonStyle(.glassProminent)
                        .tint(tint)
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.files.isEmpty)
                }
            }
        }
        .task { await model.loadInfo() }
        .task(id: model.settings.image) { await model.refreshImageEstimate() }
    }

    private func close() {
        model.cancel()
        onClose()
    }

    private func start() {
        Task {
            let done = await model.run()
            if !done.sources.isEmpty { onFinish(done.sources, .success(done.outputs)) }
            if model.files.isEmpty { onClose() }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func section(_ kind: CompressKind, model settings: Binding<CompressSettings>) -> some View {
        let count = model.files(of: kind).count
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(count > 1 ? "\(kind.title) · \(count)" : kind.title, systemImage: kind.symbol).font(.headline)
                Spacer()
                Text(Self.size(model.bytes(of: kind))).font(.callout).foregroundStyle(.secondary)
            }

            switch kind {
            case .image: imageControls(settings.image)
            case .pdf: pdfControls(settings.pdf)
            case .audio: audioControls(settings.audio)
            case .video: videoControls(settings.video)
            }
        }
        .padding(14)
        .background(.black.opacity(0.07), in: .rect(cornerRadius: 18, style: .continuous))
    }

    private func levelRow(get: @escaping () -> CompressLevel, set: @escaping (CompressLevel) -> Void) -> some View {
        row("Compression") {
            // "Custom" only shows once a detail was changed by hand.
            PillPicker(items: get() == .custom ? CompressLevel.allCases : CompressLevel.presets,
                       selection: Binding(get: get, set: { level in if level != .custom { withAnimation(.smooth(duration: 0.2)) { set(level) } } }),
                       title: \.title, tint: tint)
        }
    }

    private func imageControls(_ image: Binding<ImageCompress>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            levelRow(get: { image.wrappedValue.level }, set: { image.wrappedValue.apply($0) })
            row("Format") { PillPicker(items: ImageTarget.allCases, selection: image.target, title: \.title, tint: tint) }
            slider("Quality", "\(Int((image.wrappedValue.quality * 100).rounded()))%", image.quality, 0.1...1, step: 0.05, reset: ImageCompress().quality)
            slider("Size", "\(Int((image.wrappedValue.scale * 100).rounded()))%", image.scale, 0.1...1, step: 0.05, reset: 1)
            Toggle("Keep camera and location info", isOn: image.keepMetadata).toggleStyle(.switch).controlSize(.small).tint(tint)
            if let bytes = model.imageBytes, model.files.count == 1 {
                estimate("≈ \(Self.size(bytes))", saved: model.bytes(of: .image), now: bytes)
            }
        }
    }

    private func pdfControls(_ pdf: Binding<PDFCompress>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            levelRow(get: { pdf.wrappedValue.level }, set: { pdf.wrappedValue.apply($0) })
            row("Method") { PillPicker(items: PDFMode.allCases, selection: pdf.mode, title: \.title, tint: tint) }
            if pdf.wrappedValue.mode == .optimize {
                Toggle("Shrink pictures to screen resolution", isOn: pdf.screenImages).toggleStyle(.switch).controlSize(.small).tint(tint)
                hint("Text and vector art stay sharp and selectable.")
            } else {
                slider("Resolution", "\(Int(pdf.wrappedValue.dpi)) dpi", pdf.dpi, 50...200, step: 10, reset: PDFCompress().dpi)
                slider("Quality", "\(Int((pdf.wrappedValue.quality * 100).rounded()))%", pdf.quality, 0.2...0.95, step: 0.05, reset: PDFCompress().quality)
                Toggle("Grayscale", isOn: pdf.grayscale).toggleStyle(.switch).controlSize(.small).tint(tint)
                hint("Every page becomes a picture, so text can't be selected or searched.")
            }
        }
    }

    private func audioControls(_ audio: Binding<AudioCompress>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            levelRow(get: { audio.wrappedValue.level }, set: { audio.wrappedValue.apply($0) })
            row("Bitrate, kbps") {
                PillPicker(items: AudioCompress.bitrates, selection: audio.kbps, title: { "\($0)" }, tint: tint)
            }
            row("Sample rate") {
                PillPicker(items: AudioCompress.sampleRates, selection: audio.sampleRate,
                           title: { $0 == 0 ? String(localized: "Original") : "\(Double($0) / 1000)k".replacingOccurrences(of: ".0k", with: "k") }, tint: tint)
            }
            row("Channels") {
                PillPicker(items: [false, true], selection: audio.mono, title: { $0 ? String(localized: "Mono") : String(localized: "Original") }, tint: tint)
            }
            hint("Saved as AAC (.m4a).")
            if let info = model.info, info.duration > 0 {
                let bytes = Int64(Double(audio.wrappedValue.kbps * 1000) * info.duration / 8)
                estimate("≈ \(Self.size(bytes))", saved: model.bytes(of: .audio), now: bytes)
            }
        }
    }

    private func videoControls(_ video: Binding<VideoCompress>) -> some View {
        let value = video.wrappedValue
        let info = model.info
        let shortSide = info.map { min($0.size.width, $0.size.height) }
        let presets = [1080.0, 720, 480, 360].filter { preset in shortSide.map { preset < $0 - 1 } ?? false }
        return VStack(alignment: .leading, spacing: 12) {
            levelRow(get: { video.wrappedValue.level }, set: { video.wrappedValue.apply($0) })

            if let shortSide, !presets.isEmpty {
                let options: [CGFloat] = [0.0] + presets
                let ratio: (CGFloat) -> CGFloat = { $0 == 0 ? 1 : $0 / shortSide }
                let current: () -> CGFloat = {
                    let scale = video.wrappedValue.scale
                    return options.first { abs(ratio($0) - scale) < 0.01 } ?? -1
                }
                let selection = Binding<CGFloat>(
                    get: current,
                    set: { video.wrappedValue.scale = ratio($0) })
                let name: (CGFloat) -> String = { $0 == 0 ? String(localized: "Original") : "\(Int($0))p" }
                row("Resolution") {
                    PillPicker(items: options, selection: selection, title: name, tint: tint)
                }
            }
            slider("Scale", Self.scaleText(value.scale, info?.size), video.scale, 0.1...1, step: 0.05, reset: 1)

            row("Codec") { PillPicker(items: VideoCompress.Codec.allCases, selection: video.codec, title: \.title, tint: tint) }
            row("Limit by") { PillPicker(items: VideoCompress.Rate.allCases, selection: video.rate, title: \.title, tint: tint) }
            switch value.rate {
            case .quality:
                slider("Quality", "\(Int((value.quality * 100).rounded()))%", video.quality, 0...1, step: 0.05, reset: VideoCompress().quality)
                hint("Keeps the same look all the way through. The file size follows from the picture: busy scenes take more.")
            case .bitrate:
                slider("Video bitrate", String(format: "%.1f Mbps", value.mbps), video.mbps, 0.2...30, step: 0.1, reset: VideoCompress().mbps)
                hint(verbatim: String(format: String(localized: "About %.0f MB for every minute of video, plus the sound."), value.mbps * 7.5))
            case .size:
                let original = Double(model.bytes(of: .video)) / 1_000_000
                let limit = max(2, original.rounded(.up))
                // Opening on the middle of the range, not on a number picked for some other file.
                let wanted = max(1, (original * 0.4).rounded())
                slider("Target size", String(format: "%.0f MB", min(max(value.targetMB, 1), limit)),
                       Binding(get: { min(max(video.wrappedValue.targetMB, 1), limit) }, set: { video.wrappedValue.targetMB = $0 }),
                       1...limit, step: limit > 40 ? 1 : 0.5, reset: min(wanted, limit))
                if let info, info.duration > 0 {
                    let size = value.outputSize(of: info.size)
                    let fps = value.outputFPS(source: info.fps)
                    let bitrate = Double(value.videoBitrate(size: size, fps: fps, duration: info.duration))
                    let perPixel = bitrate / max(1, size.width * size.height * fps)
                    hint(verbatim: String(format: String(localized: "The whole file ends up near this size, so the picture gets about %.1f Mbps."), bitrate / 1_000_000)
                         + " " + String(localized: "Scale and Frame rate still apply."))
                    if perPixel < 0.03 * (value.codec == .hevc ? 0.65 : 1) {
                        Label("Too small for this picture size: it will look blocky. Lower Scale or raise the size.", systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                    }
                } else {
                    hint("The whole file ends up near this size. Scale and Frame rate still apply.")
                }
            }

            let rates = VideoCompress.frameRates.filter { rate in rate == 0 || (info.map { Double(rate) < $0.fps - 0.5 } ?? true) }
            if rates.count > 1 {
                row("Frame rate") {
                    PillPicker(items: rates, selection: video.maxFPS, title: { $0 == 0 ? String(localized: "Original") : "\($0)" }, tint: tint)
                }
            }
            row("Audio, kbps") {
                PillPicker(items: VideoCompress.audioBitrates, selection: video.audioKbps, title: { $0 == 0 ? String(localized: "Off") : "\($0)" }, tint: tint)
            }

            if let info, info.duration > 0 {
                let size = value.outputSize(of: info.size)
                let fps = value.outputFPS(source: info.fps)
                let bytes = value.estimatedBytes(size: size, fps: fps, duration: info.duration)
                estimate("\(Int(size.width))×\(Int(size.height)) · \(Int(fps.rounded())) fps · ≈ \(Self.size(bytes))",
                         saved: model.bytes(of: .video), now: bytes)
            }
        }
    }

    // MARK: Pieces

    private func row<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            content()
        }
    }

    /// Double-click puts the slider back to `reset`.
    private func slider(_ title: LocalizedStringKey, _ value: String, _ binding: Binding<Double>, _ range: ClosedRange<Double>,
                        step: Double, reset: Double) -> some View {
        VStack(spacing: 2) {
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                Text(value).monospacedDigit().contentTransition(.numericText())
            }
            ResettableSlider(value: binding, range: range, defaultValue: reset, step: step, tint: tint)
        }
    }

    private func hint(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
    }

    private func hint(verbatim text: String) -> some View {
        Text(verbatim: text).font(.callout).foregroundStyle(.secondary)
    }

    /// "≈ 1.2 MB" with how much smaller than the original that is.
    private func estimate(_ text: String, saved original: Int64, now: Int64) -> some View {
        let change = original > 0 ? 1 - Double(now) / Double(original) : 0
        return HStack {
            Text(text).font(.callout.weight(.semibold))
            Spacer()
            if original > 0 {
                Text(change >= 0 ? String(localized: "\(Int((change * 100).rounded()))% smaller") : String(localized: "\(Int((-change * 100).rounded()))% larger"))
                    .font(.callout).foregroundStyle(change >= 0 ? Color.green : Color.orange)
            }
        }
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func scaleText(_ scale: Double, _ size: CGSize?) -> String {
        let text = String(format: "%.2f×", scale)
        guard let size, size.width > 0 else { return text }
        return "\(text) · \(Int(size.width * scale / 2) * 2)×\(Int(size.height * scale / 2) * 2)"
    }
}
