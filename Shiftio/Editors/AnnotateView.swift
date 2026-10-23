import SwiftUI

enum AnnotationTool: String, CaseIterable, Identifiable {
    case arrow, rectangle, ellipse, pen, highlighter, text

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .pen: "scribble"
        case .highlighter: "highlighter"
        case .text: "textformat"
        }
    }

    var title: String {
        switch self {
        case .rectangle: String(localized: "Rectangle")
        case .arrow: String(localized: "Arrow")
        case .ellipse: String(localized: "Ellipse")
        case .pen: String(localized: "Pen")
        case .highlighter: String(localized: "Highlighter")
        case .text: String(localized: "Text")
        }
    }
}

struct Annotation: Identifiable, Equatable {
    let id = UUID()
    var tool: AnnotationTool
    /// Image pixels, top-left origin.
    var points: [CGPoint]
    var color: Color
    var width: CGFloat
    var text = ""
}

/// One drawing routine for both the live canvas and the exported image, so they always match.
enum AnnotationDrawing {
    static func draw(_ a: Annotation, in context: inout GraphicsContext) {
        guard let first = a.points.first, let last = a.points.last else { return }
        let style = StrokeStyle(lineWidth: a.width, lineCap: .round, lineJoin: .round)
        let box = CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                         width: abs(first.x - last.x), height: abs(first.y - last.y))

        switch a.tool {
        case .rectangle:
            context.stroke(Path(roundedRect: box, cornerRadius: a.width), with: .color(a.color), style: style)
        case .ellipse:
            context.stroke(Path(ellipseIn: box), with: .color(a.color), style: style)
        case .arrow:
            let angle = atan2(last.y - first.y, last.x - first.x)
            let length = max(a.width * 4.5, 16)
            let wing = { (side: CGFloat) in
                CGPoint(x: last.x - length * cos(angle + side * 0.5), y: last.y - length * sin(angle + side * 0.5))
            }
            var path = Path()
            path.move(to: first)
            path.addLine(to: last)
            path.move(to: wing(1))
            path.addLine(to: last)
            path.addLine(to: wing(-1))
            context.stroke(path, with: .color(a.color), style: style)
        case .pen, .highlighter:
            var path = Path()
            path.move(to: first)
            a.points.dropFirst().forEach { path.addLine(to: $0) }
            if a.tool == .highlighter {
                context.stroke(path, with: .color(a.color.opacity(0.35)),
                               style: StrokeStyle(lineWidth: a.width * 3.5, lineCap: .round, lineJoin: .round))
            } else {
                context.stroke(path, with: .color(a.color), style: style)
            }
        case .text:
            context.draw(Text(a.text).font(.system(size: a.width * 4, weight: .bold)).foregroundStyle(a.color),
                         at: first, anchor: .topLeading)
        }
    }
}

@MainActor @Observable
final class AnnotateModel {
    let original: EditableImage
    private(set) var items: [Annotation] = []
    private var redoStack: [Annotation] = []
    var current: Annotation?
    var tool = AnnotationTool.arrow
    var color = RGBAColor.hex(0xFF3B30).color
    var width: Double
    let defaultWidth: Double

    init(image: EditableImage) {
        original = image
        defaultWidth = (max(image.pixelSize.width, image.pixelSize.height) * 0.006).rounded()
        width = defaultWidth
    }

    var maxWidth: Double { max(original.pixelSize.width, original.pixelSize.height) * 0.03 }
    var canUndo: Bool { !items.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func commit(_ annotation: Annotation) {
        redoStack.removeAll()
        withAnimation(.smooth(duration: 0.2)) { items.append(annotation) }
    }

    func undo() {
        guard let last = items.last else { return }
        withAnimation(.smooth(duration: 0.2)) { _ = items.removeLast() }
        redoStack.append(last)
    }

    func redo() {
        guard let last = redoStack.popLast() else { return }
        withAnimation(.smooth(duration: 0.2)) { items.append(last) }
    }

    func clear() {
        withAnimation(.smooth(duration: 0.25)) { items.removeAll() }
        redoStack.removeAll()
    }

    func renderFinal() -> CGImage? {
        let size = original.pixelSize
        let items = items
        let content = ZStack {
            Image(decorative: original.image, scale: 1)
            Canvas { context, _ in items.forEach { AnnotationDrawing.draw($0, in: &context) } }
        }
        .frame(width: size.width, height: size.height)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        return renderer.cgImage
    }
}

struct AnnotateView: View {
    let image: EditableImage
    let tint: Color
    let onClose: () -> Void
    let onFinish: @MainActor (Result<[URL], Error>) -> Void

    @State private var model: AnnotateModel
    @State private var textPoint: CGPoint?
    @State private var textValue = ""
    @State private var error: String?
    @FocusState private var textFocused: Bool
    @Namespace private var toolSpace

    private static let palette: [Color] = [0xFF3B30, 0xFF9500, 0xFFCC00, 0x34C759, 0x0A84FF, 0x111111, 0xFFFFFF]
        .map { RGBAColor.hex($0).color }

    init(image: EditableImage, tint: Color, onClose: @escaping () -> Void,
         onFinish: @escaping @MainActor (Result<[URL], Error>) -> Void) {
        self.image = image
        self.tint = tint
        self.onClose = onClose
        self.onFinish = onFinish
        _model = State(initialValue: AnnotateModel(image: image))
    }

    var body: some View {
        EditorChrome(title: "Annotate", tint: tint, onClose: onClose) {
            VStack(spacing: 14) {
                canvas.frame(height: 330)
                toolPicker
                HStack(spacing: 8) {
                    ForEach(Array(Self.palette.enumerated()), id: \.offset) { _, color in
                        Button { withAnimation(.smooth(duration: 0.2)) { model.color = color } } label: {
                            Circle().fill(color).frame(width: 20, height: 20)
                                .overlay(Circle().stroke(.black.opacity(0.18), lineWidth: 0.5))
                                .overlay(Circle().stroke(tint, lineWidth: 2).padding(-3)
                                    .opacity(model.color == color ? 1 : 0))
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 8)
                    ResettableSlider(value: $model.width, range: 1...max(2, model.maxWidth), defaultValue: model.defaultWidth, tint: tint)
                        .frame(width: 120)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
        } footer: {
            HStack {
                Button { commitText(); model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .keyboardShortcut("z")
                    .disabled(!model.canUndo)
                    .help("Undo")
                Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!model.canRedo)
                    .help("Redo")
                Button(String(localized: "action.clear", defaultValue: "Clear")) { model.clear() }.disabled(!model.canUndo)
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.glassProminent)
                    .tint(tint)
                    .keyboardShortcut(.defaultAction)
            }
            .buttonStyle(.glass)
        }
        .touchBar {
            ForEach(AnnotationTool.allCases) { tool in
                Button { model.tool = tool } label: { Image(systemName: tool.symbol) }
            }
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
            Button("Save") { save() }
        }
    }

    private var toolPicker: some View {
        HStack(spacing: 2) {
            ForEach(AnnotationTool.allCases) { tool in
                let isSelected = model.tool == tool
                Button {
                    commitText()
                    withAnimation(.smooth(duration: 0.22)) { model.tool = tool }
                } label: {
                    Image(systemName: tool.symbol)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .background { if isSelected { Capsule().fill(tint).matchedGeometryEffect(id: "tool", in: toolSpace) } }
                }
                .buttonStyle(.plain)
                .help(tool.title)
            }
        }
        .padding(3)
        .background(.black.opacity(0.08), in: .capsule)
    }

    // MARK: Canvas

    private var canvas: some View {
        GeometryReader { proxy in
            let size = image.pixelSize
            let scale = min(proxy.size.width / size.width, proxy.size.height / size.height)
            let shown = CGSize(width: size.width * scale, height: size.height * scale)
            let origin = CGPoint(x: (proxy.size.width - shown.width) / 2, y: (proxy.size.height - shown.height) / 2)
            let toPixel = { (p: CGPoint) in
                CGPoint(x: min(max((p.x - origin.x) / scale, 0), size.width),
                        y: min(max((p.y - origin.y) / scale, 0), size.height))
            }

            ZStack(alignment: .topLeading) {
                Image(decorative: image.image, scale: 1)
                    .resizable()
                    .frame(width: shown.width, height: shown.height)
                    .offset(x: origin.x, y: origin.y)

                Canvas { context, _ in
                    context.translateBy(x: origin.x, y: origin.y)
                    context.scaleBy(x: scale, y: scale)
                    for item in model.items + [model.current].compactMap({ $0 }) {
                        AnnotationDrawing.draw(item, in: &context)
                    }
                }
                .allowsHitTesting(false)

                if let point = textPoint {
                    TextField("Text", text: $textValue)
                        .textFieldStyle(.roundedBorder)
                        .focused($textFocused)
                        .frame(width: 160)
                        .offset(x: min(origin.x + point.x * scale, proxy.size.width - 164),
                                y: origin.y + point.y * scale)
                        .onSubmit { commitText() }
                        .transition(.scale(scale: 0.9, anchor: .topLeading).combined(with: .opacity))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .contentShape(.rect)
            .coordinateSpace(.named("annotate"))
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("annotate"))
                    .onChanged { value in
                        guard model.tool != .text else { return }
                        let point = toPixel(value.location)
                        if var current = model.current {
                            if model.tool == .pen || model.tool == .highlighter {
                                current.points.append(point)
                            } else {
                                current.points = [current.points[0], point]
                            }
                            model.current = current
                        } else {
                            let start = toPixel(value.startLocation)
                            model.current = Annotation(tool: model.tool, points: [start, point],
                                                       color: model.color, width: model.width)
                        }
                    }
                    .onEnded { value in
                        if model.tool == .text {
                            commitText()
                            withAnimation(.smooth(duration: 0.2)) { textPoint = toPixel(value.location) }
                            textFocused = true
                        } else if let current = model.current {
                            model.current = nil
                            let travelled = hypot(value.translation.width, value.translation.height) / scale
                            if travelled > 3 { model.commit(current) }
                        }
                    }
            )
        }
    }

    private func commitText() {
        defer {
            withAnimation(.smooth(duration: 0.2)) { textPoint = nil }
            textValue = ""
        }
        let text = textValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let point = textPoint, !text.isEmpty else { return }
        var annotation = Annotation(tool: .text, points: [point], color: model.color, width: model.width)
        annotation.text = text
        model.commit(annotation)
    }

    private func save() {
        commitText()
        guard let rendered = model.renderFinal() else {
            error = String(localized: "Can't render this image")
            return
        }
        do {
            let format = ImageFormat(matching: image.url)
            let output = OutputNamer.url(for: image.url, ext: format.rawValue, suffix: "Annotated")
            try ImageConverter.write(rendered, to: output, format: format, properties: image.outputProperties,
                                     options: ActionOptions())
            onFinish(.success([output]))
        } catch {
            self.error = error.localizedDescription
        }
    }
}
