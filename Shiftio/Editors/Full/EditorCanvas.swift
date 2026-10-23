import SwiftUI

/// Transparency grid behind pictures, so transparent PNGs don't show the window through.
struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 8
            for row in 0..<Int(size.height / step) + 1 {
                for column in 0..<Int(size.width / step) + 1 where (row + column) % 2 == 0 {
                    context.fill(Path(CGRect(x: CGFloat(column) * step, y: CGFloat(row) * step, width: step, height: step)),
                                 with: .color(.gray.opacity(0.22)))
                }
            }
        }
        .background(.black.opacity(0.1))
    }
}

/// The picture being edited: zoom and scroll, plus the crop frame or the markup layer on top.
struct EditorCanvas: View {
    @Environment(\.colorScheme) private var colorScheme
    let model: FullEditorModel
    let tint: Color

    @State private var cropStart: CGRect?
    @State private var zoomStart: Double?
    @State private var textPoint: CGPoint?
    @State private var textValue = ""
    @FocusState private var textFocused: Bool

    private let margin: CGFloat = 28

    var body: some View {
        GeometryReader { viewport in
            let isCrop = model.tool == .crop
            let logical = isCrop ? model.canvasSize : model.outputSize
            let fit = max(0.0001, min((viewport.size.width - margin * 2) / logical.width,
                                      (viewport.size.height - margin * 2) / logical.height))
            let scale = fit * model.zoom
            let shown = CGSize(width: logical.width * scale, height: logical.height * scale)

            ScrollView([.horizontal, .vertical]) {
                stage(scale: scale, shown: shown, logical: logical, isCrop: isCrop)
                    .frame(width: shown.width, height: shown.height)
                    .padding(margin)
                    .frame(minWidth: viewport.size.width, minHeight: viewport.size.height)
            }
            .onAppear { model.fitScale = fit }
            .onChange(of: fit) { _, new in model.fitScale = new }
        }
        // A dark matte behind the picture in the dark look; in the light look a pale one, like the Quick Look window.
        .background(Color.black.opacity(colorScheme == .dark ? 0.28 : 0.05))
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    let start = zoomStart ?? model.zoom
                    zoomStart = start
                    model.zoom = min(8, max(0.5, start * value.magnification))
                }
                .onEnded { _ in
                    zoomStart = nil
                    model.refresh()   // re-render sharper if we zoomed in
                }
        )
        .onChange(of: model.tool) { commitText(); textPoint = nil }
    }

    // MARK: Stage

    @ViewBuilder
    private func stage(scale: CGFloat, shown: CGSize, logical: CGSize, isCrop: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            Checkerboard()
            if let preview = model.preview {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .interpolation(.high)
            }
            if isCrop {
                cropOverlay(scale: scale, shown: shown)
            } else {
                annotationLayer(scale: scale, logical: logical)
            }
        }
        .coordinateSpace(.named("stage"))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 4)
    }

    // MARK: Crop

    private func cropOverlay(scale: CGFloat, shown: CGSize) -> some View {
        let rect = model.cropRect
        let crop = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)

        return ZStack(alignment: .topLeading) {
            Rectangle().fill(.black.opacity(0.55))
                .frame(width: shown.width, height: shown.height)
                .mask {
                    ZStack(alignment: .topLeading) {
                        Rectangle()
                        Rectangle().frame(width: crop.width, height: crop.height)
                            .offset(x: crop.minX, y: crop.minY).blendMode(.destinationOut)
                    }
                    .compositingGroup()
                }
                .allowsHitTesting(false)

            Path { path in   // rule-of-thirds guides
                for i in 1...2 {
                    let x = crop.minX + crop.width * CGFloat(i) / 3, y = crop.minY + crop.height * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: crop.minY)); path.addLine(to: CGPoint(x: x, y: crop.maxY))
                    path.move(to: CGPoint(x: crop.minX, y: y)); path.addLine(to: CGPoint(x: crop.maxX, y: y))
                }
            }
            .stroke(.white.opacity(0.35), lineWidth: 0.5)
            .allowsHitTesting(false)

            Rectangle().stroke(.white, lineWidth: 1.5)
                .frame(width: crop.width, height: crop.height)
                .offset(x: crop.minX, y: crop.minY)
                .allowsHitTesting(false)

            Color.clear.contentShape(.rect)
                .frame(width: crop.width, height: crop.height)
                .offset(x: crop.minX, y: crop.minY)
                .gesture(cropDrag(handle: nil, scale: scale))

            ForEach(CropHandle.allCases, id: \.self) { handle in
                handleShape(handle)
                    .frame(width: 30, height: 30)
                    .contentShape(.rect)
                    .position(handle.point(in: crop))
                    .gesture(cropDrag(handle: handle, scale: scale))
            }
        }
        .frame(width: shown.width, height: shown.height, alignment: .topLeading)
    }

    @ViewBuilder
    private func handleShape(_ handle: CropHandle) -> some View {
        if handle.isCorner {
            RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 12, height: 12).shadow(radius: 2)
        } else if handle.movesLeft || handle.movesRight {
            Capsule().fill(.white).frame(width: 5, height: 24).shadow(radius: 2)
        } else {
            Capsule().fill(.white).frame(width: 24, height: 5).shadow(radius: 2)
        }
    }

    private func cropDrag(handle: CropHandle?, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("stage"))
            .onChanged { value in
                let start = cropStart ?? model.cropRect
                cropStart = start
                let delta = CGSize(width: value.translation.width / scale, height: value.translation.height / scale)
                let bounds = model.canvasSize
                if let handle {
                    model.setCrop(CropMath.resize(start, handle: handle, by: delta, ratio: model.cropRatio, in: bounds))
                } else {
                    model.setCrop(CropMath.move(start, by: delta, in: bounds))
                }
            }
            .onEnded { _ in cropStart = nil }
    }

    // MARK: Markup

    @ViewBuilder
    private func annotationLayer(scale: CGFloat, logical: CGSize) -> some View {
        Canvas { context, _ in
            context.scaleBy(x: scale, y: scale)
            for item in model.state.annotations + [model.currentAnnotation].compactMap({ $0 }) {
                AnnotationDrawing.draw(item, in: &context)
            }
        }
        .allowsHitTesting(false)

        if model.tool == .markup {
            Color.clear.contentShape(.rect)
                .gesture(markupDrag(scale: scale, logical: logical))

            if let point = textPoint {
                TextField("Text", text: $textValue)
                    .textFieldStyle(.roundedBorder)
                    .focused($textFocused)
                    .frame(width: 170)
                    .offset(x: point.x * scale, y: point.y * scale)
                    .onSubmit { commitText() }
            }
        }
    }

    private func markupDrag(scale: CGFloat, logical: CGSize) -> some Gesture {
        let toPixel = { (p: CGPoint) in
            CGPoint(x: min(max(p.x / scale, 0), logical.width), y: min(max(p.y / scale, 0), logical.height))
        }
        return DragGesture(minimumDistance: 0, coordinateSpace: .named("stage"))
            .onChanged { value in
                guard model.markupTool != .text else { return }
                let point = toPixel(value.location)
                if var current = model.currentAnnotation {
                    if model.markupTool == .pen || model.markupTool == .highlighter {
                        current.points.append(point)
                    } else {
                        current.points = [current.points[0], point]
                    }
                    model.currentAnnotation = current
                } else {
                    model.currentAnnotation = Annotation(tool: model.markupTool, points: [toPixel(value.startLocation), point],
                                                         color: model.markupColor, width: model.markupWidth)
                }
            }
            .onEnded { value in
                if model.markupTool == .text {
                    commitText()
                    textPoint = toPixel(value.location)
                    textFocused = true
                } else if let current = model.currentAnnotation {
                    model.currentAnnotation = nil
                    if hypot(value.translation.width, value.translation.height) / scale > 3 { model.addAnnotation(current) }
                }
            }
    }

    private func commitText() {
        defer { textPoint = nil; textValue = "" }
        let text = textValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let point = textPoint, !text.isEmpty else { return }
        var annotation = Annotation(tool: .text, points: [point], color: model.markupColor, width: model.markupWidth)
        annotation.text = text
        model.addAnnotation(annotation)
    }
}
