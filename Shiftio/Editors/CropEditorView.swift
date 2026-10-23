import SwiftUI

enum CropAspect: String, CaseIterable, Identifiable {
    case free, square, wide, tall, fourThree, threeFour

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: String(localized: "Free")
        case .square: "1:1"
        case .wide: "16:9"
        case .tall: "9:16"
        case .fourThree: "4:3"
        case .threeFour: "3:4"
        }
    }

    var ratio: CGFloat? {
        switch self {
        case .free: nil
        case .square: 1
        case .wide: 16.0 / 9
        case .tall: 9.0 / 16
        case .fourThree: 4.0 / 3
        case .threeFour: 3.0 / 4
        }
    }
}

@MainActor @Observable
final class CropModel {
    let imageSize: CGSize
    var rect: CGRect
    private(set) var aspect = CropAspect.free

    init(imageSize: CGSize) {
        self.imageSize = imageSize
        rect = CGRect(origin: .zero, size: imageSize)
    }

    var width: Int {
        get { Int(rect.width.rounded()) }
        set { resize(width: CGFloat(newValue), height: nil) }
    }

    var height: Int {
        get { Int(rect.height.rounded()) }
        set { resize(width: nil, height: CGFloat(newValue)) }
    }

    func setAspect(_ aspect: CropAspect) {
        self.aspect = aspect
        if let ratio = aspect.ratio {
            withAnimation(.smooth(duration: 0.3)) { rect = CropMath.fit(rect, ratio: ratio) }
        }
    }

    func reset() {
        aspect = .free
        withAnimation(.smooth(duration: 0.3)) { rect = CGRect(origin: .zero, size: imageSize) }
    }

    private func resize(width: CGFloat?, height: CGFloat?) {
        var w = rect.width, h = rect.height
        let minSide = CropMath.minSide
        if let width {
            w = min(max(width, minSide), imageSize.width)
            if let ratio = aspect.ratio {
                h = w / ratio
                if h > imageSize.height { h = imageSize.height; w = h * ratio }
            }
        } else if let height {
            h = min(max(height, minSide), imageSize.height)
            if let ratio = aspect.ratio {
                w = h * ratio
                if w > imageSize.width { w = imageSize.width; h = w / ratio }
            }
        }
        rect = CGRect(x: min(rect.minX, imageSize.width - w), y: min(rect.minY, imageSize.height - h), width: w, height: h)
    }
}

struct CropEditorView: View {
    let image: EditableImage
    let tint: Color
    let onClose: () -> Void
    let onFinish: @MainActor (Result<[URL], Error>) -> Void

    @State private var model: CropModel
    @State private var error: String?

    init(image: EditableImage, tint: Color, onClose: @escaping () -> Void,
         onFinish: @escaping @MainActor (Result<[URL], Error>) -> Void) {
        self.image = image
        self.tint = tint
        self.onClose = onClose
        self.onFinish = onFinish
        _model = State(initialValue: CropModel(imageSize: image.pixelSize))
    }

    var body: some View {
        EditorChrome(title: "Crop Image", tint: tint, onClose: onClose) {
            VStack(spacing: 16) {
                CropCanvas(model: model, image: image.image, tint: tint)
                    .frame(height: 340)
                    .padding(.horizontal, 24)

                HStack {
                    Text("Aspect ratio").foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: 8)
                    PillPicker(items: CropAspect.allCases,
                               selection: Binding(get: { model.aspect }, set: { model.setAspect($0) }),
                               title: \.title, tint: tint)
                }
                .padding(.horizontal, 24)

                HStack(spacing: 10) {
                    Text("W").foregroundStyle(.secondary)
                    TextField("W", value: $model.width, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder).frame(width: 84)
                    Text("H").foregroundStyle(.secondary)
                    TextField("H", value: $model.height, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder).frame(width: 84)
                    Text("px").foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 24)

                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                Spacer(minLength: 0)
            }
        } footer: {
            HStack {
                Button("Reset") { model.reset() }.buttonStyle(.glass)
                Spacer()
                Button("Apply") { apply() }
                    .buttonStyle(.glassProminent)
                    .tint(tint)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .touchBar {
            ForEach(CropAspect.allCases) { aspect in
                Button(aspect.title) { model.setAspect(aspect) }
            }
            Button("Apply") { apply() }
        }
    }

    private func apply() {
        let rect = model.rect.integral.intersection(CGRect(origin: .zero, size: model.imageSize))
        guard let cropped = image.image.cropping(to: rect) else {
            error = String(localized: "Can't crop this image")
            return
        }
        do {
            let output = OutputNamer.url(for: image.url, ext: ImageFormat(matching: image.url).rawValue, suffix: "Cropped")
            try ImageConverter.write(cropped, to: output, format: ImageFormat(matching: image.url),
                                     properties: image.outputProperties, options: ActionOptions())
            onFinish(.success([output]))
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// The image with a draggable crop frame: corner squares, edge capsules and a movable body.
private struct CropCanvas: View {
    let model: CropModel
    let image: CGImage
    let tint: Color

    @State private var dragStart: CGRect?

    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / model.imageSize.width, proxy.size.height / model.imageSize.height)
            let shown = CGSize(width: model.imageSize.width * scale, height: model.imageSize.height * scale)
            let origin = CGPoint(x: (proxy.size.width - shown.width) / 2, y: (proxy.size.height - shown.height) / 2)
            let imageFrame = CGRect(origin: origin, size: shown)
            let crop = CGRect(x: origin.x + model.rect.minX * scale, y: origin.y + model.rect.minY * scale,
                              width: model.rect.width * scale, height: model.rect.height * scale)

            ZStack {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: shown.width, height: shown.height)
                    .position(x: imageFrame.midX, y: imageFrame.midY)

                // Built from frames rather than a Path so aspect/reset changes animate smoothly.
                Rectangle().fill(.black.opacity(0.5))
                    .frame(width: imageFrame.width, height: imageFrame.height)
                    .mask {
                        ZStack(alignment: .topLeading) {
                            Rectangle()
                            Rectangle()
                                .frame(width: crop.width, height: crop.height)
                                .offset(x: crop.minX - imageFrame.minX, y: crop.minY - imageFrame.minY)
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                    }
                    .position(x: imageFrame.midX, y: imageFrame.midY)
                    .allowsHitTesting(false)

                Rectangle().stroke(tint, lineWidth: 2)
                    .frame(width: crop.width, height: crop.height)
                    .position(x: crop.midX, y: crop.midY)
                    .allowsHitTesting(false)

                Color.clear
                    .contentShape(.rect)
                    .frame(width: crop.width, height: crop.height)
                    .position(x: crop.midX, y: crop.midY)
                    .gesture(drag(handle: nil, scale: scale))

                ForEach(CropHandle.allCases, id: \.self) { handle in
                    let point = handle.point(in: crop)
                    handleShape(handle)
                        .frame(width: 30, height: 30)
                        .contentShape(.rect)
                        .position(point)
                        .gesture(drag(handle: handle, scale: scale))
                }
            }
            .coordinateSpace(.named("crop"))
        }
    }

    @ViewBuilder
    private func handleShape(_ handle: CropHandle) -> some View {
        if handle.isCorner {
            RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 12, height: 12)
        } else if handle.movesLeft || handle.movesRight {
            Capsule().fill(tint).frame(width: 5, height: 22)
        } else {
            Capsule().fill(tint).frame(width: 22, height: 5)
        }
    }

    /// Translation is measured in the fixed "crop" space, otherwise it drifts as the handle moves under the cursor.
    private func drag(handle: CropHandle?, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("crop"))
            .onChanged { value in
                let start = dragStart ?? model.rect
                dragStart = start
                let delta = CGSize(width: value.translation.width / scale, height: value.translation.height / scale)
                if let handle {
                    model.rect = CropMath.resize(start, handle: handle, by: delta, ratio: model.aspect.ratio, in: model.imageSize)
                } else {
                    model.rect = CropMath.move(start, by: delta, in: model.imageSize)
                }
            }
            .onEnded { _ in dragStart = nil }
    }
}
