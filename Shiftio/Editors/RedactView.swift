import SwiftUI
import Vision

enum RedactStyle: String, CaseIterable, Identifiable {
    case black, pixelate
    var id: String { rawValue }
    var title: String { self == .black ? String(localized: "Black") : String(localized: "Pixelate") }
}

struct RedactBox: Identifiable, Equatable {
    let id = UUID()
    var rect: CGRect   // image pixels, top-left origin
}

/// Applies redactions to the pixels themselves. Nothing underneath survives in the saved file.
enum Redactor {
    private static let context = CIContext()

    static func render(_ image: CGImage, boxes: [CGRect], style: RedactStyle) -> CGImage? {
        let width = image.width, height = image.height
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let pixelated: CIImage? = style == .pixelate
            ? CIImage(cgImage: image).applyingFilter("CIPixellate", parameters: [
                kCIInputScaleKey: max(10, CGFloat(min(width, height)) / 40),
                kCIInputCenterKey: CIVector(x: 0, y: 0),
            ])
            : nil

        for box in boxes {
            // Core Graphics and Core Image both use a bottom-left origin.
            let rect = CGRect(x: box.minX, y: CGFloat(height) - box.maxY, width: box.width, height: box.height).integral
            if let pixelated, let patch = context.createCGImage(pixelated.cropped(to: rect), from: rect) {
                ctx.draw(patch, in: rect)
            } else {
                ctx.setFillColor(CGColor(gray: 0, alpha: 1))
                ctx.fill(rect)
            }
        }
        return ctx.makeImage()
    }

    static func detectText(in image: CGImage) async throws -> [CGRect] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        let size = CGSize(width: image.width, height: image.height)
        let observations = try await request.perform(on: image)
        return observations.map { observation in
            observation.boundingBox.toImageCoordinates(size, origin: .upperLeft).insetBy(dx: -4, dy: -3)
        }
    }
}

@MainActor @Observable
final class RedactModel {
    let original: EditableImage
    var boxes: [RedactBox] = []
    var style = RedactStyle.black
    var isDetecting = false
    var message: String?

    init(image: EditableImage) { original = image }

    var size: CGSize { original.pixelSize }

    func add(_ rect: CGRect) {
        let clamped = rect.intersection(CGRect(origin: .zero, size: size))
        guard clamped.width >= 6, clamped.height >= 6 else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { boxes.append(RedactBox(rect: clamped)) }
    }

    func remove(_ box: RedactBox) {
        withAnimation(.smooth(duration: 0.2)) { boxes.removeAll { $0.id == box.id } }
    }

    func detectText() async {
        isDetecting = true
        defer { isDetecting = false }
        do {
            let found = try await Redactor.detectText(in: original.image)
            message = found.isEmpty ? String(localized: "No text found") : nil
            let bounds = CGRect(origin: .zero, size: size)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                for rect in found where !boxes.contains(where: { $0.rect.intersects(rect) && $0.rect.intersection(rect).width > rect.width / 2 }) {
                    boxes.append(RedactBox(rect: rect.intersection(bounds)))
                }
            }
        } catch {
            message = error.localizedDescription
        }
    }
}

struct RedactView: View {
    let image: EditableImage
    let tint: Color
    let onClose: () -> Void
    let onFinish: @MainActor (Result<[URL], Error>) -> Void

    @State private var model: RedactModel
    @State private var draft: CGRect?

    init(image: EditableImage, tint: Color, onClose: @escaping () -> Void,
         onFinish: @escaping @MainActor (Result<[URL], Error>) -> Void) {
        self.image = image
        self.tint = tint
        self.onClose = onClose
        self.onFinish = onFinish
        _model = State(initialValue: RedactModel(image: image))
    }

    var body: some View {
        EditorChrome(title: "Redact", tint: tint, onClose: onClose) {
            VStack(spacing: 14) {
                canvas.frame(height: 340)

                HStack {
                    Text("Style").foregroundStyle(.secondary)
                    Spacer()
                    PillPicker(items: RedactStyle.allCases, selection: $model.style, title: \.title, tint: tint)
                }

                HStack {
                    Button {
                        Task { await model.detectText() }
                    } label: {
                        if model.isDetecting { ProgressView().controlSize(.small) }
                        Label("Find Text", systemImage: "text.viewfinder")
                    }
                    .buttonStyle(.glass)
                    .disabled(model.isDetecting)
                    Text(model.message ?? (model.boxes.isEmpty ? String(localized: "Drag over what to hide") : String(localized: "\(model.boxes.count) hidden")))
                        .font(.callout).foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                    Spacer()
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
        } footer: {
            HStack {
                Button(String(localized: "action.clear", defaultValue: "Clear")) { withAnimation(.smooth) { model.boxes.removeAll() } }
                    .buttonStyle(.glass)
                    .disabled(model.boxes.isEmpty)
                Spacer()
                Button("Save Redacted") { save() }
                    .buttonStyle(.glassProminent)
                    .tint(tint)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.boxes.isEmpty)
            }
        }
        .touchBar {
            Button("Find Text") { Task { await model.detectText() } }
            Button(model.style == .black ? "Pixelate" : "Black") {
                model.style = model.style == .black ? .pixelate : .black
            }
            Button("Save") { save() }
        }
    }

    private var canvas: some View {
        GeometryReader { proxy in
            let size = model.size
            let scale = min(proxy.size.width / size.width, proxy.size.height / size.height)
            let shown = CGSize(width: size.width * scale, height: size.height * scale)
            let origin = CGPoint(x: (proxy.size.width - shown.width) / 2, y: (proxy.size.height - shown.height) / 2)

            ZStack(alignment: .topLeading) {
                Image(decorative: image.image, scale: 1)
                    .resizable()
                    .frame(width: shown.width, height: shown.height)
                    .offset(x: origin.x, y: origin.y)

                ForEach(model.boxes) { box in
                    boxView(box.rect, scale: scale, origin: origin, committed: true)
                        .overlay(alignment: .topTrailing) {
                            Button { model.remove(box) } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 16))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                            .offset(x: 6, y: -6)
                            .position(x: (box.rect.maxX * scale + origin.x), y: (box.rect.minY * scale + origin.y))
                        }
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
                if let draft {
                    boxView(draft, scale: scale, origin: origin, committed: false)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .contentShape(.rect)
            .coordinateSpace(.named("redact"))
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named("redact"))
                    .onChanged { value in
                        draft = pixelRect(value.startLocation, value.location, scale: scale, origin: origin)
                    }
                    .onEnded { value in
                        model.add(pixelRect(value.startLocation, value.location, scale: scale, origin: origin))
                        draft = nil
                    }
            )
        }
    }

    private func boxView(_ rect: CGRect, scale: CGFloat, origin: CGPoint, committed: Bool) -> some View {
        Rectangle()
            .fill(model.style == .black ? AnyShapeStyle(.black.opacity(committed ? 0.94 : 0.5))
                                        : AnyShapeStyle(.gray.opacity(committed ? 0.75 : 0.4)))
            .overlay(Rectangle().stroke(tint, lineWidth: committed ? 0 : 1.5))
            .frame(width: rect.width * scale, height: rect.height * scale)
            .offset(x: origin.x + rect.minX * scale, y: origin.y + rect.minY * scale)
    }

    private func pixelRect(_ a: CGPoint, _ b: CGPoint, scale: CGFloat, origin: CGPoint) -> CGRect {
        let p = CGPoint(x: (a.x - origin.x) / scale, y: (a.y - origin.y) / scale)
        let q = CGPoint(x: (b.x - origin.x) / scale, y: (b.y - origin.y) / scale)
        let bounds = CGRect(origin: .zero, size: model.size)
        return CGRect(x: min(p.x, q.x), y: min(p.y, q.y), width: abs(p.x - q.x), height: abs(p.y - q.y)).intersection(bounds)
    }

    private func save() {
        guard let rendered = Redactor.render(image.image, boxes: model.boxes.map(\.rect), style: model.style) else {
            model.message = String(localized: "Can't render this image")
            return
        }
        do {
            let format = ImageFormat(matching: image.url)
            let output = OutputNamer.url(for: image.url, ext: format.rawValue, suffix: "Redacted")
            // No metadata on purpose: EXIF thumbnails can contain the unredacted picture.
            try ImageConverter.write(rendered, to: output, format: format, properties: nil, options: ActionOptions())
            onFinish(.success([output]))
        } catch {
            model.message = error.localizedDescription
        }
    }
}
