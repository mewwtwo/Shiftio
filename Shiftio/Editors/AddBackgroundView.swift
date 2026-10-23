import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum BackgroundRatio: String, CaseIterable, Identifiable {
    case auto, square, wide, portrait

    var id: String { rawValue }
    var title: String { ["auto": String(localized: "Auto"), "square": "1:1", "wide": "16:9", "portrait": "4:5"][rawValue]! }
    var value: CGFloat? {
        switch self {
        case .auto: nil
        case .square: 1
        case .wide: 16.0 / 9
        case .portrait: 4.0 / 5
        }
    }
}

struct BackgroundPreset: Identifiable {
    let id: String
    let fill: BackgroundFill

    static let gradients: [BackgroundPreset] = [
        [0xF2683A, 0xF0508A, 0x8B5CF6], [0xFFFFFF, 0xC9B6F2], [0xFFD66B, 0xFF8FB1, 0x7AA8FF],
        [0xF7C8E8, 0xD9C7F7, 0xFFFFFF], [0x1B1F3B, 0x7B2FF7, 0xF107A3], [0xFFFFFF, 0x9BD3FF],
        [0x4FD1C5, 0x3B82F6], [0xFEE140, 0xFA709A], [0x0F2027, 0x2C5364],
    ].enumerated().map { index, colors in
        BackgroundPreset(id: "g\(index)", fill: .gradient(colors.map { RGBAColor.hex($0) }))
    }

    static let solids: [BackgroundPreset] = [
        0xFFFFFF, 0xF8D568, 0xA3D95B, 0x3FA66B, 0x34A89A, 0x6CC9E0, 0x3B6FE0, 0x1F2A4A, 0x8B5CC6, 0x111111,
    ].enumerated().map { index, color in
        BackgroundPreset(id: "s\(index)", fill: .solid(RGBAColor.hex(color)))
    }
}

@MainActor @Observable
final class BackgroundModel {
    let original: EditableImage
    let previewSource: CGImage

    var selectedID = "g0"
    var customColor = Color.blue
    var customImage: CGImage?
    var padding: Double
    var corners: Double
    var shadow: Double
    var ratio = BackgroundRatio.auto

    let defaults: (padding: Double, corners: Double, shadow: Double)

    init(image: EditableImage) {
        original = image
        previewSource = image.image.scaled(maxSide: 1400)
        let side = max(image.pixelSize.width, image.pixelSize.height)
        defaults = ((side * 0.05).rounded(), (side * 0.055).rounded(), (side * 0.008).rounded())
        (padding, corners, shadow) = defaults
    }

    var maxSide: Double { max(original.pixelSize.width, original.pixelSize.height) }

    var fill: BackgroundFill {
        if selectedID == "custom-color" { return .solid(RGBAColor(customColor)) }
        if selectedID == "custom-image", let customImage { return .image(customImage) }
        return (BackgroundPreset.gradients + BackgroundPreset.solids).first { $0.id == selectedID }?.fill
            ?? BackgroundPreset.gradients[0].fill
    }

    var settings: BackgroundSettings {
        BackgroundSettings(fill: fill, padding: padding, corners: corners, shadow: shadow, ratio: ratio.value)
    }

    func reset() {
        selectedID = "g0"
        (padding, corners, shadow) = defaults
        ratio = .auto
    }

    func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let loaded = try? EditableImage(url: url) else { return }
        customImage = loaded.image.scaled(maxSide: 4000)
        selectedID = "custom-image"
    }

    func preview() -> CGImage? {
        let canvas = BackgroundRenderer.canvasSize(for: original.pixelSize, settings: settings)
        let scale = min(1, 700 / max(canvas.width, canvas.height))
        return BackgroundRenderer.render(previewSource, originalSize: original.pixelSize, settings: settings, scale: scale)
    }

    func renderFinal() -> CGImage? {
        BackgroundRenderer.render(original.image, originalSize: original.pixelSize, settings: settings)
    }
}

struct AddBackgroundView: View {
    let image: EditableImage
    let tint: Color
    let onClose: () -> Void
    let onFinish: @MainActor (Result<[URL], Error>) -> Void

    @State private var model: BackgroundModel
    @State private var error: String?

    init(image: EditableImage, tint: Color, onClose: @escaping () -> Void,
         onFinish: @escaping @MainActor (Result<[URL], Error>) -> Void) {
        self.image = image
        self.tint = tint
        self.onClose = onClose
        self.onFinish = onFinish
        _model = State(initialValue: BackgroundModel(image: image))
    }

    var body: some View {
        EditorChrome(title: "Add BG", tint: tint, onClose: onClose) {
            VStack(spacing: 14) {
                previewArea
                backgroundPicker
                VStack(spacing: 6) {
                    ParamSlider(title: "Padding", value: $model.padding, range: 0...(model.maxSide * 0.25),
                                defaultValue: model.defaults.padding, tint: tint)
                    ParamSlider(title: "Corners", value: $model.corners, range: 0...(model.maxSide * 0.2),
                                defaultValue: model.defaults.corners, tint: tint)
                    ParamSlider(title: "Shadow", value: $model.shadow, range: 0...(model.maxSide * 0.04),
                                defaultValue: model.defaults.shadow, tint: tint)
                }
                HStack {
                    Text("Ratio").foregroundStyle(.secondary)
                    Spacer()
                    PillPicker(items: BackgroundRatio.allCases, selection: $model.ratio, title: \.title, tint: tint)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
        } footer: {
            HStack {
                Button("Reset") { model.reset() }.buttonStyle(.glass)
                Spacer()
                Button("Save with Background") { save() }
                    .buttonStyle(.glassProminent)
                    .tint(tint)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .touchBar {
            Slider(value: $model.padding, in: 0...(model.maxSide * 0.25)) { Text("Padding") }
                .frame(width: 200)
            Slider(value: $model.corners, in: 0...(model.maxSide * 0.2)) { Text("Corners") }
                .frame(width: 200)
            Slider(value: $model.shadow, in: 0...(model.maxSide * 0.04)) { Text("Shadow") }
                .frame(width: 200)
            Button("Save") { save() }
        }
    }

    private var previewArea: some View {
        Group {
            if let preview = model.preview() {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .clipShape(.rect(cornerRadius: 6))
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 300)
    }

    private var backgroundPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Background").foregroundStyle(.secondary)
            swatchRow(BackgroundPreset.gradients, trailing: AnyView(imageButton))
            swatchRow(BackgroundPreset.solids, trailing: AnyView(customColorButton))
        }
    }

    private func swatchRow(_ presets: [BackgroundPreset], trailing: AnyView) -> some View {
        HStack(spacing: 7) {
            ForEach(presets) { preset in
                Button { model.selectedID = preset.id } label: {
                    swatch(preset.fill).overlay(selectionRing(preset.id))
                }
                .buttonStyle(.plain)
            }
            trailing
        }
    }

    @ViewBuilder
    private func swatch(_ fill: BackgroundFill) -> some View {
        switch fill {
        case .gradient(let colors):
            Circle().fill(LinearGradient(colors: colors.map(\.color), startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 22, height: 22)
        case .solid(let color):
            Circle().fill(color.color).frame(width: 22, height: 22)
                .overlay(Circle().stroke(.black.opacity(0.15), lineWidth: 0.5))
        case .image(let picture):
            Image(decorative: picture, scale: 1).resizable().scaledToFill().frame(width: 22, height: 22).clipShape(.circle)
        }
    }

    private func selectionRing(_ id: String) -> some View {
        Circle().stroke(tint, lineWidth: 2).padding(-3).opacity(model.selectedID == id ? 1 : 0)
    }

    private var imageButton: some View {
        Button { model.chooseImage() } label: {
            Image(systemName: "photo").font(.system(size: 11))
                .frame(width: 22, height: 22)
                .background(.black.opacity(0.1), in: .circle)
                .overlay(selectionRing("custom-image"))
        }
        .buttonStyle(.plain)
        .help("Use a picture as background")
    }

    private var customColorButton: some View {
        ColorPicker("", selection: Binding(get: { model.customColor },
                                           set: { model.customColor = $0; model.selectedID = "custom-color" }))
            .labelsHidden()
            .scaleEffect(0.8)
            .frame(width: 26, height: 22)
            .clipped()
    }

    private func save() {
        guard let rendered = model.renderFinal() else {
            error = String(localized: "Can't render this image")
            return
        }
        do {
            let output = OutputNamer.url(for: image.url, ext: "png", suffix: "Background")
            try ImageConverter.write(rendered, to: output, format: .png, properties: nil, options: ActionOptions())
            onFinish(.success([output]))
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct ParamSlider: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Text(title).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
            ResettableSlider(value: $value, range: range, defaultValue: defaultValue, tint: tint)
            Text("\(Int(value.rounded())) px")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .trailing)
        }
    }
}
