import AVKit
import SwiftUI

struct VideoEditorView: View {
    let tint: Color
    let onClose: () -> Void
    let onFinish: @MainActor (Result<[URL], Error>) -> Void

    @State private var model: VideoEditModel
    /// `-ShiftioVideoTab sound|overlay|save` opens on that tab (for screenshots).
    @State private var tab = VideoToolTab(rawValue: UserDefaults.standard.string(forKey: "ShiftioVideoTab") ?? "") ?? .clip

    init(url: URL, tint: Color, onClose: @escaping () -> Void,
         onFinish: @escaping @MainActor (Result<[URL], Error>) -> Void) {
        self.tint = tint
        self.onClose = onClose
        self.onFinish = onFinish
        _model = State(initialValue: VideoEditModel(url: url))
    }

    var body: some View {
        EditorChrome(title: "Edit Video", tint: tint, onClose: onClose) {
            VStack(spacing: 12) {
                PlayerSurface(player: model.player)
                    .frame(height: 270)
                    .overlay { OverlayPreview(model: model, tint: tint, editing: tab == .overlay) }
                    .clipShape(.rect(cornerRadius: 14, style: .continuous))
                    .overlay { if !model.isLoaded { ProgressView() } }
                    .contentShape(.rect)
                    .onTapGesture { model.togglePlay() }

                TrimTimeline(model: model, tint: tint)
                    .frame(height: 52)
                    .disabled(!model.isLoaded)

                HStack {
                    Text(Self.format(model.mode == .trim ? model.start : model.cutStart)).foregroundStyle(.secondary)
                    Spacer()
                    Text(Self.format(model.current)).contentTransition(.numericText())
                    Spacer()
                    Text(Self.format(model.mode == .trim ? model.end : model.cutEnd)).foregroundStyle(.secondary)
                }
                .font(.callout.monospacedDigit())
                .padding(.horizontal, 14)

                HStack {
                    PillPicker(items: VideoEditMode.allCases, selection: $model.mode, title: \.title, tint: tint)
                    Spacer()
                    if !model.cuts.isEmpty {
                        Button("Restore Cuts") { withAnimation(.smooth) { model.restoreCuts() } }
                            .buttonStyle(.glass)
                    }
                    if model.mode == .cut {
                        Button { Task { await model.removeSilence() } } label: {
                            if model.isFindingSilence { ProgressView().controlSize(.small) }
                            Label("Silence", systemImage: "waveform.badge.minus")
                        }
                        .buttonStyle(.glass)
                        .disabled(!model.hasAudio || model.isMuted || model.isFindingSilence)
                        .help("Cut out every pause in the sound")
                        Button { withAnimation(.smooth) { model.cutOut() } } label: {
                            Label("Cut Out", systemImage: "scissors")
                        }
                        .buttonStyle(.glassProminent)
                        .tint(.red)
                    }
                }
                .disabled(!model.isLoaded)

                HStack(spacing: 8) {
                    Button { model.togglePlay() } label: {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 16)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .keyboardShortcut(.space, modifiers: [])
                    .help("Play / pause (space)")

                    Text(model.message ?? (model.mode == .trim ? String(localized: "Drag the handles to trim") : String(localized: "Select a piece, then Cut Out")))
                        .font(.callout).foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if !model.splits.isEmpty {
                        tool("xmark", help: "Remove the splits") { withAnimation(.smooth) { model.clearSplits() } }
                    }
                    tool("rectangle.split.2x1", help: "Split here: the parts are saved as separate files") { model.split() }
                    tool("camera.viewfinder", help: "Save this frame as a picture") { Task { await model.saveFrame() } }
                }

                PillPicker(items: VideoToolTab.allCases, selection: $tab, title: \.title, tint: tint)

                VStack(spacing: 12) {
                    switch tab {
                    case .clip: clipTools
                    case .picture: pictureTools
                    case .sound: soundTools
                    case .overlay: overlayTools
                    case .save: saveTools
                    }
                }
                .frame(height: 150, alignment: .top)
                .disabled(!model.isLoaded)
            }
            .padding(.horizontal, 24)
        } footer: {
            HStack {
                Text(model.isLoaded ? String(localized: "Result \(Self.format(model.length))\(sizeText)") : "")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                formatMenu
                Button { save() } label: {
                    if model.isSaving { ProgressView().controlSize(.small) }
                    Text("Save")
                }
                .buttonStyle(.glassProminent)
                .tint(tint)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSave)
            }
        }
        .background {
            // Arrow keys step by a frame, with Shift by a second, like the system players.
            Group {
                Button("Back") { model.step(frames: -1) }.keyboardShortcut(.leftArrow, modifiers: [])
                Button("Forward") { model.step(frames: 1) }.keyboardShortcut(.rightArrow, modifiers: [])
                Button("Back 1s") { model.step(seconds: -1) }.keyboardShortcut(.leftArrow, modifiers: .shift)
                Button("Forward 1s") { model.step(seconds: 1) }.keyboardShortcut(.rightArrow, modifiers: .shift)
            }
            .opacity(0).accessibilityHidden(true)
        }
        .task { await model.load() }
        .task(id: model.sizeKey) { await model.refreshEstimate() }
        .onDisappear {
            model.pause()
            model.cleanUp()
        }
    }

    private var sizeText: String {
        guard let bytes = model.estimatedSize else { return "" }
        return String(localized: " · up to ") + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func save() {
        Task {
            do {
                onFinish(.success(try await model.export()))
            } catch {
                model.message = error.localizedDescription
            }
        }
    }

    // MARK: Tool panels

    private var clipTools: some View {
        VStack(spacing: 12) {
            row("Speed") {
                PillPicker(items: VideoExporter.speeds, selection: $model.speed,
                           title: { $0 == 1 ? "1×" : "\($0.formatted())×" }, tint: tint)
            }
            row("Fade") {
                HStack(spacing: 8) {
                    fadeMenu(String(localized: "fade.in", defaultValue: "In"), $model.fadeIn)
                    fadeMenu(String(localized: "fade.out", defaultValue: "Out"), $model.fadeOut)
                }
                .help("Fades are applied when you save")
            }
            row("Join") {
                HStack(spacing: 8) {
                    if !model.joined.isEmpty {
                        Text("\(model.joined.count) added · \(Self.format(model.joinedLength))")
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        Button { withAnimation(.smooth) { model.removeJoined() } } label: { Image(systemName: "xmark") }
                            .buttonStyle(.glass).buttonBorderShape(.circle).tint(Color(white: 0.55)).help("Remove the added clips")
                    }
                    Button { Task { await model.chooseClipsToJoin() } } label: {
                        Label("Add Clips…", systemImage: "plus.rectangle.on.rectangle")
                    }
                    .buttonStyle(.glass)
                    .help("Put other videos after this one")
                }
            }
            row("Play") {
                PillPicker(items: [false, true], selection: $model.reversed, title: { $0 ? String(localized: "Backwards") : String(localized: "Forwards") }, tint: tint)
            }
            .disabled(model.output.group == .audio)
        }
    }

    private var pictureTools: some View {
        VStack(spacing: 12) {
            row("Crop") { PillPicker(items: VideoCrop.allCases, selection: $model.crop, title: \.title, tint: tint) }
            row("Turn") {
                HStack(spacing: 8) {
                    tool("rotate.right", help: "Rotate 90°") { Task { await model.rotate() } }
                    tool("arrow.left.and.right.righttriangle.left.righttriangle.right", help: "Flip horizontally", active: model.flipped) {
                        Task { await model.flip() }
                    }
                }
            }
        }
    }

    private var soundTools: some View {
        VStack(spacing: 10) {
            row("Sound") {
                PillPicker(items: [false, true], selection: $model.isMuted, title: { $0 ? String(localized: "Off") : String(localized: "On") }, tint: tint)
            }
            VStack(spacing: 2) {
                HStack {
                    Text("Volume").foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int((model.volume * 100).rounded()))%").monospacedDigit()
                }
                ResettableSlider(value: $model.volume, range: 0...2, defaultValue: 1, step: 0.05, tint: tint)
            }
            .opacity(model.isMuted ? 0.4 : 1)
            .disabled(model.isMuted)
            row("Improve") {
                HStack(spacing: 8) {
                    if model.isProcessingSound { ProgressView().controlSize(.small) }
                    toggle("Normalize", $model.normalizes, help: "Bring the level of speech to a comfortable, even volume")
                    toggle("Reduce Noise", $model.reducesNoise, help: "Cut rumble and turn down hiss between words")
                        .disabled(model.replacementSound != nil)
                }
            }
            .disabled(model.isMuted || !model.hasSound)
            row("Replace") {
                HStack(spacing: 8) {
                    if let file = model.replacementSound {
                        Text(file.lastPathComponent).font(.callout).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).frame(maxWidth: 150)
                        Button { model.removeSoundtrack() } label: { Image(systemName: "xmark") }
                            .buttonStyle(.glass).buttonBorderShape(.circle).tint(Color(white: 0.55)).help("Use the clip's own sound again")
                    }
                    Button { Task { await model.chooseSoundtrack() } } label: { Label("Choose…", systemImage: "music.note") }
                        .buttonStyle(.glass)
                        .help("Use the sound of another file instead")
                }
            }
        }
    }

    private var overlayTools: some View {
        VStack(spacing: 10) {
            row("Watermark") {
                HStack(spacing: 8) {
                    PillPicker(items: WatermarkMode.allCases, selection: $model.watermarkMode, title: \.title, tint: tint)
                    if model.watermarkMode != .off {
                        menu(verbatim: model.watermarkCorner.title) {
                            Picker("Position", selection: $model.watermarkCorner) {
                                ForEach(WatermarkCorner.allCases) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.inline)
                        }
                        menu(verbatim: model.watermarkSize.title) {
                            Picker("Size", selection: $model.watermarkSize) {
                                ForEach(WatermarkSize.allCases) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.inline)
                        }
                    }
                }
            }
            switch model.watermarkMode {
            case .off:
                EmptyView()
            case .text:
                HStack(spacing: 12) {
                    TextField("Text on the video", text: $model.watermarkText)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.black.opacity(0.08), in: .capsule)
                    opacityControl
                }
            case .image:
                HStack(spacing: 12) {
                    Button { model.chooseWatermarkImage() } label: {
                        Label(model.watermarkImage == nil ? "Choose Picture…" : "Change Picture…", systemImage: "photo")
                    }
                    .buttonStyle(.glass)
                    Spacer(minLength: 0)
                    opacityControl
                }
            }
            row("Hide") {
                HStack(spacing: 8) {
                    if !model.blurs.isEmpty {
                        Button { withAnimation(.smooth) { model.removeBlur() } } label: { Image(systemName: "minus") }
                            .buttonStyle(.glass).buttonBorderShape(.circle).help("Remove the selected area")
                    }
                    Button { withAnimation(.smooth) { model.addBlur(pixelates: false) } } label: { Label("Blur", systemImage: "drop") }
                        .buttonStyle(.glass).help("Blur an area of the picture; drag it into place")
                    Button { withAnimation(.smooth) { model.addBlur(pixelates: true) } } label: { Label("Pixelate", systemImage: "squareshape.split.3x3") }
                        .buttonStyle(.glass).help("Cover an area with blocks")
                }
            }
            row("Subtitles") {
                HStack(spacing: 8) {
                    if model.isTranscribing { ProgressView().controlSize(.small) }
                    PillPicker(items: SubtitleMode.allCases, selection: $model.subtitleMode, title: \.title, tint: tint)
                }
            }
            .disabled(!model.hasAudio || model.isTranscribing)
        }
    }

    /// Every format the clip can be saved as. Lives next to the Save button so it is never out of sight.
    private var formatMenu: some View {
        menu(verbatim: model.output.title) {
            Picker("Format", selection: $model.output) {
                ForEach(SaveFormat.Group.allCases) { group in
                    Section(group.title) {
                        ForEach(SaveFormat.formats(in: group)) { format in Text(format.menuTitle).tag(format) }
                    }
                }
            }
            .pickerStyle(.inline)
        }
        .help("Save as: \(model.output.menuTitle)")
    }

    private var presetMenu: some View {
        menu("Preset") {
            ForEach(VideoPreset.allCases) { preset in
                Button { model.apply(preset) } label: { Text("\(preset.title) · \(preset.detail)") }
            }
        }
        .help("Settings for WhatsApp, Telegram, Instagram, Discord or the web")
    }

    private var saveTools: some View {
        VStack(spacing: 10) {
            row("Format") {
                HStack(spacing: 8) {
                    if model.output.group == .video { presetMenu }
                    formatMenu
                }
            }
            switch model.output.group {
            case .video:
                row("Size") { PillPicker(items: VideoResolution.allCases, selection: $model.resolution, title: \.title, tint: tint) }
                if model.output != .prores {
                    row("Limit") {
                        PillPicker(items: [nil, 8, 10, 16, 25, 50] as [Int?], selection: $model.sizeLimitMB,
                                   title: { $0.map { "\($0) MB" } ?? String(localized: "Off") }, tint: tint)
                    }
                }
            case .animated:
                row("Frame rate") { PillPicker(items: GIFOptions.frameRates, selection: $model.gif.fps, title: { "\($0)" }, tint: tint) }
                row("Width") { PillPicker(items: GIFOptions.widths, selection: $model.gif.width, title: { "\($0) px" }, tint: tint) }
            case .audio:
                if model.output == .mp3 {
                    row("Bitrate") { PillPicker(items: [128, 192, 256, 320], selection: $model.mp3Bitrate, title: { "\($0)" }, tint: tint) }
                } else {
                    hint(verbatim: model.hasSound ? String(localized: "Only the sound, with the edits, as \(model.output.title).") : String(localized: "This video has no sound to save."))
                }
            }
            if model.output.group != .animated {
                row("Metadata") {
                    PillPicker(items: [false, true], selection: $model.stripsMetadata, title: { $0 ? String(localized: "Remove") : String(localized: "Keep") }, tint: tint)
                }
            }
        }
    }

    private var opacityControl: some View {
        HStack(spacing: 8) {
            Text("Opacity").foregroundStyle(.secondary)
            ResettableSlider(value: $model.watermarkOpacity, range: 0.05...1, defaultValue: VideoEditModel.defaultOpacity, step: 0.05, tint: tint)
                .frame(width: 110)
            Text("\(Int((model.watermarkOpacity * 100).rounded()))%").monospacedDigit().frame(width: 40, alignment: .trailing)
        }
        .fixedSize()
    }

    /// A menu that looks like the other glass buttons. `.buttonStyle(.glass)` on a `Menu` draws it greyed out like a disabled
    /// control, so the glass is drawn by the label instead, the way the zoom menu of the picture editor does.
    private func menu<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        menu(Text(title), content: content)
    }

    private func menu<Content: View>(verbatim title: String, @ViewBuilder content: () -> Content) -> some View {
        menu(Text(verbatim: title), content: content)
    }

    private func menu<Content: View>(_ title: Text, @ViewBuilder content: () -> Content) -> some View {
        Menu(content: content) {
            HStack(spacing: 6) {
                title.font(.system(size: 13, weight: .medium))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .adaptiveGlass(interactive: true, in: Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func toggle(_ title: LocalizedStringKey, _ value: Binding<Bool>, help: LocalizedStringKey) -> some View {
        Button { value.wrappedValue.toggle() } label: { Text(title) }
            .buttonStyle(.glass)
            .tint(value.wrappedValue ? tint : nil)
            .help(help)
    }

    private func row<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            content()
        }
    }

    private func hint(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hint(verbatim text: String) -> some View {
        Text(verbatim: text).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fadeMenu(_ title: String, _ value: Binding<Double>) -> some View {
        menu(verbatim: "\(title) · " + (value.wrappedValue == 0 ? String(localized: "Off") : "\(value.wrappedValue.formatted()) s")) {
            Picker(title, selection: value) {
                ForEach([0, 0.5, 1, 2], id: \.self) { Text($0 == 0 ? String(localized: "Off") : "\($0.formatted()) s").tag($0) }
            }
            .pickerStyle(.inline)
        }
    }

    private func tool(_ symbol: String, help: LocalizedStringKey, enabled: Bool = true, active: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 18)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .tint(active ? tint : Color(white: 0.55))
        .disabled(!model.isLoaded || !enabled)
        .help(help)
    }

    static func format(_ seconds: Double) -> String {
        let tenths = Int((max(0, seconds) * 10).rounded())
        return String(format: "%d:%02d.%d", tenths / 600, tenths / 10 % 60, tenths % 10)
    }
}

enum VideoToolTab: String, CaseIterable, Identifiable {
    case clip, picture, sound, overlay, save
    var id: String { rawValue }
    var title: String {
        switch self {
        case .clip: String(localized: "Clip")
        case .picture: String(localized: "Picture")
        case .sound: String(localized: "Sound")
        case .overlay: String(localized: "Overlay")
        case .save: String(localized: "Save As")
        }
    }
}

/// Where the watermark and the areas to hide land on the picture. The areas can be dragged and resized while the Overlay tab is open.
private struct OverlayPreview: View {
    let model: VideoEditModel
    let tint: Color
    let editing: Bool

    var body: some View {
        GeometryReader { proxy in
            let area = Self.fit(aspect: model.outputAspect, in: proxy.size)
            ZStack(alignment: .topLeading) {
                if let mark = model.watermarkImage, model.watermarkCorner == .tiled {
                    let cells = WatermarkTiling.cells(imageSize: CGSize(width: mark.width, height: mark.height), in: area.size,
                                                      fraction: model.watermarkSize.rawValue)
                    Canvas { context, size in
                        let picture = context.resolve(Image(decorative: mark, scale: 1))
                        context.opacity = model.watermarkOpacity
                        context.translateBy(x: size.width / 2, y: size.height / 2)
                        context.rotate(by: .radians(WatermarkTiling.angle))
                        context.translateBy(x: -size.width / 2, y: -size.height / 2)
                        for cell in cells { context.draw(picture, in: cell) }
                    }
                    .frame(width: area.width, height: area.height)
                    .clipped()
                    .allowsHitTesting(false)
                } else if let mark = model.watermarkImage {
                    let rect = model.watermarkCorner.rect(imageSize: CGSize(width: mark.width, height: mark.height), in: area.size,
                                                          fraction: model.watermarkSize.rawValue)
                    Image(decorative: mark, scale: 1).resizable()
                        .frame(width: rect.width, height: rect.height)
                        .opacity(model.watermarkOpacity)
                        .offset(x: rect.minX, y: rect.minY)
                }
                ForEach(model.blurs) { blur in
                    BlurBox(model: model, blur: blur, size: area.size, tint: tint, selected: editing && model.selectedBlur == blur.id)
                }
            }
            .frame(width: area.width, height: area.height, alignment: .topLeading)
            .offset(x: area.minX, y: area.minY)
        }
        .allowsHitTesting(editing)
    }

    /// The largest rectangle of the given shape that fits, centred.
    static func fit(aspect: CGFloat, in size: CGSize) -> CGRect {
        guard aspect > 0, size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: size) }
        let width = min(size.width, size.height * aspect)
        let height = width / aspect
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }
}

private struct BlurBox: View {
    let model: VideoEditModel
    let blur: VideoBlur
    let size: CGSize
    let tint: Color
    let selected: Bool

    @State private var movingFrom: CGRect?
    @State private var resizingFrom: CGRect?

    var body: some View {
        let rect = CGRect(x: blur.rect.minX * size.width, y: blur.rect.minY * size.height,
                          width: blur.rect.width * size.width, height: blur.rect.height * size.height)
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(selected ? tint : .white.opacity(0.7), lineWidth: 2)
            }
            .overlay {
                if blur.pixelates { Image(systemName: "squareshape.split.3x3").foregroundStyle(.white.opacity(0.8)) }
            }
            .overlay(alignment: .bottomTrailing) {
                Circle().fill(tint).frame(width: 14, height: 14)
                    .overlay { Circle().strokeBorder(.white, lineWidth: 2) }
                    .padding(-7)
                    .gesture(DragGesture(minimumDistance: 1).onChanged { drag in
                        let base = resizingFrom ?? blur.rect
                        resizingFrom = base
                        model.selectedBlur = blur.id
                        model.setBlur(blur.id, rect: CGRect(x: base.minX, y: base.minY,
                                                            width: base.width + drag.translation.width / size.width,
                                                            height: base.height + drag.translation.height / size.height))
                    }.onEnded { _ in resizingFrom = nil })
            }
            .frame(width: rect.width, height: rect.height)
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 1).onChanged { drag in
                let base = movingFrom ?? blur.rect
                movingFrom = base
                model.selectedBlur = blur.id
                model.setBlur(blur.id, rect: base.offsetBy(dx: drag.translation.width / size.width, dy: drag.translation.height / size.height))
            }.onEnded { _ in movingFrom = nil })
            .onTapGesture { model.selectedBlur = blur.id }
            .offset(x: rect.minX, y: rect.minY)
    }
}

private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = false
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}
}

/// Thumbnail strip with a playhead and two handles (the kept range, or the piece to cut out), worked like the trim
/// bar in QuickTime: the handle follows the pointer exactly, the frame under it shows while it moves, and the cursor
/// turns into a resize arrow over it. A press near a handle moves that handle, anywhere else scrubs.
/// Mouse events come from an AppKit layer (`TimelineHitLayer`), which takes the first click like any macOS control.
private struct TrimTimeline: View {
    let model: VideoEditModel
    let tint: Color

    private let handle: CGFloat = 16
    /// How far from a handle's centre a press still grabs it.
    private let reach: CGFloat = 24

    private enum Grab {
        case handle(VideoHandle, base: Double)
        /// Both handles at once. A press that never moves is only a click, which seeks.
        case range(base: (Double, Double), pressed: Double)
        case scrub
    }
    @State private var grab: Grab?
    @State private var didMove = false

    private var handles: (VideoHandle, VideoHandle) {
        model.mode == .trim ? (.trimStart, .trimEnd) : (.cutStart, .cutEnd)
    }

    private var accent: Color { model.mode == .trim ? tint : .red }

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width - handle * 2)
            let duration = max(model.duration, 0.001)
            let inset = handle
            let x = { (time: Double) -> CGFloat in inset + time / duration * width }
            let time = { (x: CGFloat) -> Double in (x - inset) / width * duration }
            let (first, second) = handles
            let a = model.time(of: first), b = model.time(of: second)
            // Where the two grips are centred.
            let centres = [x(a) - handle / 2, x(b) + handle / 2]
            // The stretch between the grips moves as one, unless it already is the whole clip.
            let canSlide = b - a < duration - 0.01
            let body = CGRect(x: x(a), y: 0, width: max(0, x(b) - x(a)), height: proxy.size.height)

            ZStack(alignment: .topLeading) {
                strip.frame(width: width).offset(x: handle)
                    .clipShape(.rect(cornerRadius: 6, style: .continuous))

                // Outside the trim, and the pieces already cut out.
                Rectangle().fill(.black.opacity(0.55)).frame(width: x(model.start) - handle).offset(x: handle)
                Rectangle().fill(.black.opacity(0.55)).frame(width: handle + width - x(model.end)).offset(x: x(model.end))
                ForEach(model.cuts, id: \.lowerBound) { cut in
                    Rectangle().fill(.black.opacity(0.7))
                        .overlay { Rectangle().fill(.red.opacity(0.35)) }
                        .overlay(alignment: .center) { Image(systemName: "scissors").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.8)) }
                        .frame(width: max(2, x(cut.upperBound) - x(cut.lowerBound)))
                        .offset(x: x(cut.lowerBound))
                }

                // Frame around the range the handles hold.
                Rectangle().fill(accent).frame(width: x(b) - x(a), height: 3).offset(x: x(a))
                Rectangle().fill(accent).frame(width: x(b) - x(a), height: 3).offset(x: x(a), y: proxy.size.height - 3)
                if model.mode == .cut {
                    Rectangle().fill(.red.opacity(0.25)).frame(width: x(b) - x(a)).offset(x: x(a))
                }

                ForEach(model.splits, id: \.self) { time in
                    Rectangle().fill(.white.opacity(0.9)).frame(width: 2, height: proxy.size.height).offset(x: x(time) - 1)
                }

                Capsule().fill(.white).frame(width: 3, height: proxy.size.height + 6)
                    .shadow(radius: 2)
                    .offset(x: x(model.current) - 1.5, y: -3)

                grip(systemName: "chevron.compact.left", leading: true).offset(x: x(a) - handle)
                grip(systemName: "chevron.compact.right", leading: false).offset(x: x(b))
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .overlay {
                TimelineHitLayer(grabAreas: centres.map { CGRect(x: $0 - handle, y: 0, width: handle * 2, height: proxy.size.height) },
                                 bodyArea: canSlide ? body : nil,
                                 began: { start in
                    didMove = false
                    // The nearer grip wins, so two handles side by side never hide each other.
                    let candidates = [(first, abs(start - centres[0])), (second, abs(start - centres[1]))]
                    if let nearest = candidates.min(by: { $0.1 < $1.1 }), nearest.1 <= reach {
                        grab = .handle(nearest.0, base: model.time(of: nearest.0))
                    } else if abs(start - x(model.current)) <= 8 {
                        grab = .scrub
                    } else if canSlide, start > x(a), start < x(b) {
                        grab = .range(base: (a, b), pressed: time(start))
                    } else {
                        grab = .scrub
                        scrub(to: time(start))
                    }
                }, moved: { current, start in
                    if abs(current - start) > 2 { didMove = true }
                    switch grab {
                    case .handle(let which, let base)?:
                        model.set(which, to: base + Double((current - start) / width) * duration)
                    case .range(let base, _)?:
                        guard didMove else { return }
                        model.moveRange(model.mode, from: base, by: Double((current - start) / width) * duration)
                    default:
                        scrub(to: time(current))
                    }
                }, ended: {
                    // A click inside the range, without dragging, jumps the playhead there.
                    if case .range(_, let pressed)? = grab, !didMove { scrub(to: pressed) }
                    grab = nil
                    model.commitSeek()
                })
            }
        }
    }

    private func scrub(to time: Double) {
        model.pause()
        model.seek(to: min(max(time, model.start), model.end), precise: false)
    }

    private var strip: some View {
        HStack(spacing: 0) {
            ForEach(0..<VideoEditModel.thumbnailCount, id: \.self) { index in
                Color.black.opacity(0.25)
                    .overlay {
                        if index < model.thumbnails.count, let image = model.thumbnails[index] {
                            Image(decorative: image, scale: 1).resizable().scaledToFill()
                        }
                    }
                    .clipped()
            }
        }
    }

    private func grip(systemName: String, leading: Bool) -> some View {
        UnevenRoundedRectangle(topLeadingRadius: leading ? 8 : 0, bottomLeadingRadius: leading ? 8 : 0,
                               bottomTrailingRadius: leading ? 0 : 8, topTrailingRadius: leading ? 0 : 8,
                               style: .continuous)
            .fill(accent)
            .frame(width: handle)
            .overlay { Image(systemName: systemName).font(.system(size: 14, weight: .bold)).foregroundStyle(.white) }
    }
}

/// Catches the mouse over the timeline. `began` gets the x of the press, `moved` the current x and the pressed x.
private struct TimelineHitLayer: NSViewRepresentable {
    var grabAreas: [CGRect]
    /// Between the handles; the pointer becomes an open hand there.
    var bodyArea: CGRect?
    var began: (CGFloat) -> Void
    var moved: (CGFloat, CGFloat) -> Void
    var ended: () -> Void

    func makeNSView(context: Context) -> HitView { HitView() }

    func updateNSView(_ view: HitView, context: Context) {
        view.began = began
        view.moved = moved
        view.ended = ended
        view.grabAreas = grabAreas
        view.bodyArea = bodyArea
    }

    final class HitView: NSView {
        var began: (CGFloat) -> Void = { _ in }
        var moved: (CGFloat, CGFloat) -> Void = { _, _ in }
        var ended: () -> Void = {}
        var grabAreas: [CGRect] = [] {
            didSet { if grabAreas != oldValue { window?.invalidateCursorRects(for: self) } }
        }
        var bodyArea: CGRect? {
            didSet { if bodyArea != oldValue { window?.invalidateCursorRects(for: self) } }
        }
        private var pressedX: CGFloat = 0

        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            if let bodyArea { addCursorRect(bodyArea, cursor: .openHand) }
            for area in grabAreas { addCursorRect(area, cursor: .resizeLeftRight) }
        }

        private func x(of event: NSEvent) -> CGFloat { convert(event.locationInWindow, from: nil).x }

        override func mouseDown(with event: NSEvent) {
            pressedX = x(of: event)
            began(pressedX)
        }

        override func mouseDragged(with event: NSEvent) { moved(x(of: event), pressedX) }
        override func mouseUp(with event: NSEvent) { ended() }
    }
}
