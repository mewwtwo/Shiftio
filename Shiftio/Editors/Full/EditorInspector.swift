import SwiftUI

/// The right-hand panel: tool tabs, then the controls of the selected tool.
struct EditorInspector: View {
    let model: FullEditorModel
    let tint: Color

    var body: some View {
        VStack(spacing: 0) {
            ToolTabs(model: model, tint: tint)
                .padding(10)
            Divider().opacity(0.5)
            ScrollView {
                Group {
                    switch model.tool {
                    case .adjust: AdjustPanel(model: model, tint: tint)
                    case .filters: FiltersPanel(model: model, tint: tint)
                    case .crop: CropPanel(model: model, tint: tint)
                    case .markup: MarkupPanel(model: model, tint: tint)
                    }
                }
                .padding(14)
            }
            .scrollIndicators(.never)
        }
        .adaptiveGlass(large: true, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .animation(.smooth(duration: 0.2), value: model.tool)
    }
}

private struct ToolTabs: View {
    let model: FullEditorModel
    let tint: Color
    @Namespace private var space

    var body: some View {
        HStack(spacing: 2) {
            ForEach(FullEditorModel.Tool.allCases) { tool in
                let isSelected = model.tool == tool
                Button { withAnimation(.smooth(duration: 0.25)) { model.select(tool) } } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tool.symbol).font(.system(size: 16))
                            .frame(height: 20)
                        Text(tool.title).font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.gradient)
                                .matchedGeometryEffect(id: "tab", in: space)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(.primary.opacity(0.07), in: .rect(cornerRadius: 15, style: .continuous))
    }
}

// MARK: Shared rows

/// A labelled slider: double-click resets it, and the value reads as -100…+100 like Photos.
struct EditorSliderRow: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    let neutral: Double
    let tint: Color
    var valueText: ((Double) -> String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 12))
                Spacer()
                Text(valueText?(value) ?? Self.relative(value, range: range, neutral: neutral))
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(value == neutral ? .tertiary : .secondary)
            }
            ResettableSlider(value: $value, range: range, defaultValue: neutral, tint: tint)
        }
    }

    static func relative(_ value: Double, range: ClosedRange<Double>, neutral: Double) -> String {
        let span = value >= neutral ? range.upperBound - neutral : neutral - range.lowerBound
        guard span > 0 else { return "0" }
        return String(format: "%+.0f", ((value - neutral) / span * 100).rounded())
    }
}

// MARK: Adjust

private struct AdjustPanel: View {
    let model: FullEditorModel
    let tint: Color
    @State private var expanded: Set<EditAdjustments.Group> = [.light, .color]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HistogramView(histogram: model.histogram)
                .frame(height: 76)

            Toggle(isOn: model.binding(\.adjustments.autoEnhance)) {
                Label("Auto Enhance", systemImage: "wand.and.stars").font(.system(size: 13, weight: .medium))
            }
            .toggleStyle(.switch)
            .tint(tint)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(.primary.opacity(0.06), in: .rect(cornerRadius: 12, style: .continuous))

            ForEach(EditAdjustments.Group.allCases) { group in
                AdjustSection(model: model, group: group, tint: tint, isExpanded: Binding(
                    get: { expanded.contains(group) },
                    set: { if $0 { expanded.insert(group) } else { expanded.remove(group) } }))
            }
        }
    }
}

private struct AdjustSection: View {
    let model: FullEditorModel
    let group: EditAdjustments.Group
    let tint: Color
    @Binding var isExpanded: Bool

    private func row(_ title: LocalizedStringKey, _ keyPath: WritableKeyPath<EditAdjustments, Double>,
                     _ range: ClosedRange<Double>, _ neutral: Double) -> some View {
        let base: WritableKeyPath<EditState, EditAdjustments> = \.adjustments
        return EditorSliderRow(title: title, value: model.binding(base.appending(path: keyPath)),
                               range: range, neutral: neutral, tint: tint)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { withAnimation(.smooth(duration: 0.25)) { isExpanded.toggle() } } label: {
                    HStack(spacing: 8) {
                        Image(systemName: group.symbol).frame(width: 18).foregroundStyle(.secondary)
                        Text(group.title).font(.system(size: 13, weight: .semibold))
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                Spacer()
                if model.state.adjustments.isModified(group) {
                    Button("Reset") { model.resetGroup(group) }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(tint)
                        .transition(.opacity)
                }
            }

            if isExpanded {
                VStack(spacing: 10) {
                    switch group {
                    case .light:
                        row("Exposure", \.exposure, -2...2, 0)
                        row("Brightness", \.brightness, -0.5...0.5, 0)
                        row("Contrast", \.contrast, 0.5...1.5, 1)
                        row("Highlights", \.highlights, -1...0, 0)
                        row("Shadows", \.shadows, -1...1, 0)
                    case .color:
                        row("Saturation", \.saturation, 0...2, 1)
                        row("Vibrance", \.vibrance, -1...1, 0)
                        row("Warmth", \.warmth, -1...1, 0)
                        row("Tint", \.tint, -1...1, 0)
                    case .detail:
                        row("Sharpness", \.sharpness, 0...2, 0)
                        row("Clarity", \.clarity, 0...1, 0)
                        row("Noise Reduction", \.noiseReduction, 0...1, 0)
                    case .effects:
                        row("Fade", \.fade, 0...1, 0)
                        row("Grain", \.grain, 0...1, 0)
                        row("Vignette", \.vignette, 0...1, 0)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .background(.primary.opacity(0.06), in: .rect(cornerRadius: 12, style: .continuous))
        .animation(.smooth(duration: 0.25), value: model.state.adjustments.isModified(group))
    }
}

private struct HistogramView: View {
    let histogram: EditHistogram?

    var body: some View {
        Canvas { context, size in
            guard let histogram else { return }
            let peak = Double(histogram.peak)
            func path(_ bins: [Int]) -> Path {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: size.height))
                    for index in 0..<256 {
                        let x = size.width * CGFloat(index) / 255
                        let y = size.height * (1 - CGFloat(min(1, Double(bins[index]) / peak)))
                        p.addLine(to: CGPoint(x: x, y: y))
                    }
                    p.addLine(to: CGPoint(x: size.width, y: size.height))
                    p.closeSubpath()
                }
            }
            context.fill(path(histogram.luma), with: .color(.white.opacity(0.22)))
            context.blendMode = .plusLighter
            context.fill(path(histogram.red), with: .color(.red.opacity(0.5)))
            context.fill(path(histogram.green), with: .color(.green.opacity(0.5)))
            context.fill(path(histogram.blue), with: .color(.blue.opacity(0.6)))
        }
        .background(.black.opacity(0.35), in: .rect(cornerRadius: 8, style: .continuous))
        .animation(.smooth(duration: 0.2), value: histogram)
    }
}

// MARK: Filters

private struct FiltersPanel: View {
    let model: FullEditorModel
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 14) {
                ForEach(EditFilter.allCases) { filter in
                    FilterCell(model: model, filter: filter, tint: tint)
                }
            }
            if model.state.filter != .none {
                EditorSliderRow(title: "Intensity", value: model.binding(\.filterAmount), range: 0...1, neutral: 1,
                                tint: tint, valueText: { "\(Int(($0 * 100).rounded()))" })
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.smooth(duration: 0.25), value: model.state.filter)
    }
}

private struct FilterCell: View {
    let model: FullEditorModel
    let filter: EditFilter
    let tint: Color

    var body: some View {
        let isSelected = model.state.filter == filter
        Button { model.mutate { $0.filter = filter } } label: {
            VStack(spacing: 5) {
                // The picture is an overlay on a fixed box, so a wide image can't stretch the cell.
                Color.primary.opacity(0.08)
                    .frame(maxWidth: .infinity)
                    .frame(height: 70)
                    .overlay {
                        if let thumbnail = model.thumbnails[filter] {
                            Image(decorative: thumbnail, scale: 1).resizable().scaledToFill()
                        }
                    }
                    .clipShape(.rect(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(tint, lineWidth: 2.5).opacity(isSelected ? 1 : 0)
                }
                Text(filter.title).font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .animation(.smooth(duration: 0.2), value: isSelected)
    }
}

// MARK: Crop

private struct CropPanel: View {
    let model: FullEditorModel
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Aspect Ratio").font(.system(size: 13, weight: .semibold))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(EditAspect.allCases) { aspect in
                    let isSelected = model.state.geometry.aspect == aspect
                    Button { withAnimation(.smooth(duration: 0.25)) { model.setAspect(aspect) } } label: {
                        Text(aspect.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                            .frame(maxWidth: .infinity, minHeight: 30)
                            .background(isSelected ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(.primary.opacity(0.08)),
                                        in: .rect(cornerRadius: 9, style: .continuous))
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider().opacity(0.4)
            EditorSliderRow(title: "Straighten", value: model.binding(\.geometry.straighten), range: -45...45, neutral: 0,
                            tint: tint, valueText: { String(format: "%+.1f°", $0) })

            HStack(spacing: 8) {
                iconButton("rotate.left", "Rotate left") { model.rotate(-1) }
                iconButton("rotate.right", "Rotate right") { model.rotate(1) }
                iconButton("arrow.left.and.right.righttriangle.left.righttriangle.right", "Flip horizontally") {
                    model.flip(horizontal: true)
                }
                iconButton("arrow.up.and.down.righttriangle.up.righttriangle.down", "Flip vertically") {
                    model.flip(horizontal: false)
                }
            }

            Divider().opacity(0.4)
            HStack {
                Text("Result").foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(model.outputSize.width)) × \(Int(model.outputSize.height)) px").monospacedDigit()
            }
            .font(.system(size: 12))

            Button("Reset Crop & Rotation") { withAnimation(.smooth) { model.resetCrop() } }
                .buttonStyle(.bordered)
                .tint(nil)
                .disabled(model.state.geometry == EditGeometry())

            if !model.state.annotations.isEmpty {
                Label("Changing the crop removes markup.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
        }
    }

    private func iconButton(_ symbol: String, _ help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14)).frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(.bordered)
        .tint(nil)
        .help(help)
    }
}

// MARK: Markup

private struct MarkupPanel: View {
    let model: FullEditorModel
    let tint: Color

    private static let palette: [Color] = [0xFF3B30, 0xFF9500, 0xFFCC00, 0x34C759, 0x0A84FF, 0xAF52DE, 0x111111, 0xFFFFFF]
        .map { RGBAColor.hex($0).color }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            Text("Draw on the picture").font(.system(size: 13, weight: .semibold))

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(AnnotationTool.allCases) { tool in
                    let isSelected = model.markupTool == tool
                    Button { withAnimation(.smooth(duration: 0.2)) { model.markupTool = tool } } label: {
                        VStack(spacing: 4) {
                            Image(systemName: tool.symbol).font(.system(size: 16))
                            Text(tool.title).font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(isSelected ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(.primary.opacity(0.08)),
                                    in: .rect(cornerRadius: 10, style: .continuous))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                ForEach(Array(Self.palette.enumerated()), id: \.offset) { _, color in
                    Button { withAnimation(.smooth(duration: 0.2)) { model.markupColor = color } } label: {
                        Circle().fill(color).frame(width: 22, height: 22)
                            .overlay(Circle().stroke(.black.opacity(0.2), lineWidth: 0.5))
                            .overlay(Circle().stroke(tint, lineWidth: 2).padding(-3).opacity(model.markupColor == color ? 1 : 0))
                    }
                    .buttonStyle(.plain)
                }
            }

            EditorSliderRow(title: "Thickness", value: $model.markupWidth,
                            range: 1...max(2, max(model.fullSize.width, model.fullSize.height) * 0.03),
                            neutral: model.defaultMarkupWidth, tint: tint, valueText: { "\(Int($0.rounded())) px" })

            Text("Markup is drawn onto the saved picture. Undo with ⌘Z.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

// MARK: Export

struct ExportPanel: View {
    let model: FullEditorModel
    let tint: Color
    let saveCopy: () -> Void
    let replaceOriginal: () -> Void

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 14) {
            Text("Export").font(.system(size: 13, weight: .semibold))

            Picker("Format", selection: $model.export.format) {
                ForEach(ExportFormat.allCases) { Text($0.title).tag($0) }
            }

            if model.export.format.usesQuality || (model.export.format == .original && ImageFormat(matching: model.image.url).supportsQuality) {
                EditorSliderRow(title: "Quality", value: $model.export.quality, range: 0.3...1, neutral: 0.9, tint: tint,
                                valueText: { "\(Int(($0 * 100).rounded()))%" })
            }

            Picker("Largest side", selection: $model.export.maxSide) {
                Text("Original").tag(0)
                ForEach([4096, 2560, 1920, 1280, 800], id: \.self) { Text("\($0) px").tag($0) }
            }

            Toggle("Keep metadata", isOn: $model.export.keepMetadata).tint(tint)
            Toggle("Remove location", isOn: $model.export.removeLocation)
                .disabled(!model.export.keepMetadata)
                .tint(tint)

            Divider()
            Button(action: saveCopy) { Text("Save as Copy").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).tint(tint).keyboardShortcut(.defaultAction)
            Button(action: replaceOriginal) { Text("Replace Original…").frame(maxWidth: .infinity) }
                .buttonStyle(.bordered)
            Text("The original moves to the Trash, so you can get it back.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 270)
    }
}

private extension ImageFormat {
    var supportsQuality: Bool { self == .jpg || self == .heic }
}
