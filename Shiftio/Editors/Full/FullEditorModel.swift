import AppKit
import ImageIO
import Observation
import SwiftUI

@MainActor @Observable
final class FullEditorModel {
    enum Tool: String, CaseIterable, Identifiable {
        case adjust, filters, crop, markup

        var id: String { rawValue }
        var title: String {
            switch self {
            case .adjust: String(localized: "Adjust")
            case .filters: String(localized: "Filters")
            case .crop: String(localized: "Crop")
            case .markup: String(localized: "Markup")
            }
        }
        var symbol: String {
            switch self {
            case .adjust: "slider.horizontal.3"
            case .filters: "camera.filters"
            case .crop: "crop.rotate"
            case .markup: "pencil.tip.crop.circle"
            }
        }
    }

    let image: EditableImage
    let fullSize: CGSize
    private let renderer: FullEditRenderer

    private(set) var state = EditState()
    private(set) var preview: CGImage?
    private(set) var histogram: EditHistogram?
    private(set) var thumbnails: [EditFilter: CGImage] = [:]
    private(set) var isSaving = false
    var errorMessage: String?

    private(set) var tool = Tool.adjust
    var zoom = 1.0
    /// Points per picture pixel when the picture just fits; set by the canvas, used for "Actual size".
    var fitScale = 1.0
    private(set) var isComparing = false

    var export = ExportOptions()

    // Markup pen
    var markupTool = AnnotationTool.arrow
    var markupColor = RGBAColor.hex(0xFF3B30).color
    var markupWidth: Double
    let defaultMarkupWidth: Double
    var currentAnnotation: Annotation?

    private var undoStack: [EditState] = []
    private var redoStack: [EditState] = []
    private var lastMutation = Date.distantPast
    private var renderTask: Task<Void, Never>?
    private var thumbnailTask: Task<Void, Never>?

    init(image: EditableImage) {
        self.image = image
        fullSize = image.pixelSize
        renderer = FullEditRenderer(full: image.image)
        defaultMarkupWidth = (max(fullSize.width, fullSize.height) * 0.006).rounded()
        markupWidth = defaultMarkupWidth
        // The file is on screen at once; edited renders replace it as they finish.
        preview = image.image.scaled(maxSide: 1500)
        // `-ShiftioEditorTool filters|crop|markup` opens on that tab (for screenshots).
        if let name = UserDefaults.standard.string(forKey: "ShiftioEditorTool"), let tool = Tool(rawValue: name) { self.tool = tool }
        if tool == .filters { refreshThumbnails() }
        Task { [renderer] in await renderer.warmUp() }
        refresh()
    }

    // MARK: Derived geometry

    var canvasSize: CGSize { EditGeometryMath.canvasSize(fullSize, state.geometry) }
    var cropRect: CGRect { EditGeometryMath.crop(fullSize, state.geometry) }
    var outputSize: CGSize { CGSize(width: cropRect.width.rounded(), height: cropRect.height.rounded()) }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Picture proportions the crop is locked to, or nil for free-form.
    var cropRatio: CGFloat? {
        state.geometry.aspect.ratio(for: EditGeometryMath.oriented(fullSize, state.geometry))
    }

    // MARK: Editing

    /// Applies a change and records it for undo. Changes arriving within half a second of each other
    /// (a slider drag, a crop drag) share one undo step.
    func mutate(_ change: (inout EditState) -> Void) {
        let before = state
        var after = state
        change(&after)
        guard after != before else { return }
        if after.geometry != before.geometry && after.annotations == before.annotations { after.annotations = [] }

        if Date.now.timeIntervalSince(lastMutation) > 0.5 {
            undoStack.append(before)
            if undoStack.count > 200 { undoStack.removeFirst() }
        }
        lastMutation = .now
        redoStack.removeAll()
        state = after
        refresh()
    }

    func binding<T: Equatable>(_ keyPath: WritableKeyPath<EditState, T>) -> Binding<T> {
        Binding(get: { self.state[keyPath: keyPath] }, set: { value in self.mutate { $0[keyPath: keyPath] = value } })
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(state)
        state = previous
        lastMutation = .distantPast
        refresh()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(state)
        state = next
        lastMutation = .distantPast
        refresh()
    }

    func revertAll() {
        lastMutation = .distantPast
        mutate { $0 = EditState() }
    }

    func resetGroup(_ group: EditAdjustments.Group) {
        lastMutation = .distantPast
        mutate { $0.adjustments.reset(group) }
    }

    // MARK: Geometry

    func rotate(_ turns: Int) {
        lastMutation = .distantPast
        mutate { $0.geometry.quarterTurns = (($0.geometry.quarterTurns + turns) % 4 + 4) % 4; $0.geometry.crop = nil }
    }

    func flip(horizontal: Bool) {
        lastMutation = .distantPast
        mutate {
            if horizontal { $0.geometry.flipH.toggle() } else { $0.geometry.flipV.toggle() }
            $0.geometry.crop = nil
        }
    }

    func setStraighten(_ degrees: Double) {
        mutate { $0.geometry.straighten = degrees; $0.geometry.crop = nil }
    }

    func setAspect(_ aspect: EditAspect) {
        lastMutation = .distantPast
        mutate { $0.geometry.aspect = aspect; $0.geometry.crop = nil }
    }

    func setCrop(_ rect: CGRect) {
        mutate { $0.geometry.crop = rect }
    }

    func resetCrop() {
        lastMutation = .distantPast
        mutate { $0.geometry = EditGeometry() }
    }

    func addAnnotation(_ annotation: Annotation) {
        lastMutation = .distantPast
        mutate { $0.annotations.append(annotation) }
    }

    // MARK: Tools and rendering

    func select(_ tool: Tool) {
        guard tool != self.tool else { return }
        self.tool = tool
        if tool == .filters { refreshThumbnails() }
        refresh()
    }

    func setComparing(_ comparing: Bool) {
        guard comparing != isComparing else { return }
        isComparing = comparing
        refresh()
    }

    func refresh() {
        renderTask?.cancel()
        let snapshot = state
        let mode: FullEditRenderer.Mode = tool == .crop ? .canvas : (isComparing ? .original : .result)
        let side = zoom > 1.25 ? 3200 : 1500
        renderTask = Task { [renderer] in
            guard let rendered = await renderer.render(snapshot, maxSide: side, mode: mode), !Task.isCancelled else { return }
            preview = rendered
            if mode != .original {
                let computed = await Task.detached(priority: .utility) { EditHistogram.compute(rendered) }.value
                if !Task.isCancelled { histogram = computed }
            }
        }
        if tool == .filters { refreshThumbnails() }
    }

    func refreshThumbnails() {
        thumbnailTask?.cancel()
        var snapshot = state
        snapshot.filter = .none
        thumbnailTask = Task { [renderer] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let result = await renderer.thumbnails(snapshot)
            if !Task.isCancelled, !result.isEmpty { thumbnails = result }
        }
    }

    // MARK: Saving

    /// The finished picture: full resolution, with markup drawn in and the chosen size limit applied.
    private func renderOutput() async -> CGImage? {
        guard var output = await renderer.renderFinal(state) else { return nil }
        if !state.annotations.isEmpty {
            let size = CGSize(width: output.width, height: output.height)
            let annotations = state.annotations
            let base = output
            let content = ZStack {
                Image(decorative: base, scale: 1)
                Canvas { context, _ in annotations.forEach { AnnotationDrawing.draw($0, in: &context) } }
            }
            .frame(width: size.width, height: size.height)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 1
            if let composed = renderer.cgImage { output = composed }
        }
        if export.maxSide > 0 { output = output.scaled(maxSide: CGFloat(export.maxSide)) }
        return output
    }

    func save(replacingOriginal: Bool) async -> URL? {
        isSaving = true
        defer { isSaving = false }
        guard let rendered = await renderOutput() else {
            errorMessage = String(localized: "Can't render this image")
            return nil
        }
        let format = export.format.imageFormat(matching: image.url)
        var properties: [CFString: Any]? = export.keepMetadata ? image.outputProperties : nil
        if export.removeLocation { properties?[kCGImagePropertyGPSDictionary] = nil }
        do {
            let output: URL
            if replacingOriginal {
                // The original goes to the Trash, so this can still be undone from Finder.
                try FileManager.default.trashItem(at: image.url, resultingItemURL: nil)
                output = image.url.deletingPathExtension().appendingPathExtension(format.rawValue)
            } else {
                output = OutputNamer.url(for: image.url, ext: format.rawValue, suffix: "Edited")
            }
            try ImageConverter.write(rendered, to: output, format: format, properties: properties,
                                     options: ActionOptions(jpegQuality: export.quality))
            return output
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
}
