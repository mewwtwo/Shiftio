import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Actions that open a window instead of converting right away.
protocol EditorAction: FileAction {
    /// `complete` is not called when the user closes the window without saving.
    @MainActor func present(_ url: URL, tint: Color, complete: @escaping @MainActor (Result<[URL], Error>) -> Void)
    /// Editors that take every dragged file in one window (Compress) say so, and get them all at once.
    var handlesBatch: Bool { get }
    @MainActor func presentBatch(_ urls: [URL], tint: Color,
                                 complete: @escaping @MainActor (_ sources: [URL], Result<[URL], Error>) -> Void)
}

extension EditorAction {
    var handlesBatch: Bool { false }
    @MainActor func presentBatch(_ urls: [URL], tint: Color,
                                 complete: @escaping @MainActor (_ sources: [URL], Result<[URL], Error>) -> Void) {}

    var kind: ActionKind { .editor }
    func run(_ urls: [URL], options: ActionOptions) async throws -> [URL] { throw ShiftioError.needsEditor }
}

struct CropAction: EditorAction {
    var id: String { "crop" }
    var title: String { String(localized: "Crop") }
    var symbol: String? { "crop" }
    var inputTypes: [UTType] { [.image] }

    @MainActor
    func present(_ url: URL, tint: Color, complete: @escaping @MainActor (Result<[URL], Error>) -> Void) {
        do {
            let image = try EditableImage(url: url)
            EditorWindowController.shared.present(size: CGSize(width: 420, height: 530)) { close in
                CropEditorView(image: image, tint: tint, onClose: close) { result in
                    complete(result)
                    if case .success = result { close() }
                }
            }
        } catch {
            complete(.failure(error))
        }
    }
}

struct AddBackgroundAction: EditorAction {
    var id: String { "add-bg" }
    var title: String { String(localized: "Add BG") }
    var symbol: String? { "photo.artframe" }
    var inputTypes: [UTType] { [.image] }

    @MainActor
    func present(_ url: URL, tint: Color, complete: @escaping @MainActor (Result<[URL], Error>) -> Void) {
        do {
            let image = try EditableImage(url: url)
            EditorWindowController.shared.present(size: CGSize(width: 420, height: 650)) { close in
                AddBackgroundView(image: image, tint: tint, onClose: close) { result in
                    complete(result)
                    if case .success = result { close() }
                }
            }
        } catch {
            complete(.failure(error))
        }
    }
}

/// Opens one of the image editors in a glass window; keeps each action to its view and size.
@MainActor
private func presentImageEditor<Editor: View>(
    _ url: URL, size: CGSize, tint: Color,
    complete: @escaping @MainActor (Result<[URL], Error>) -> Void,
    editor: @escaping (EditableImage, @escaping () -> Void, @escaping @MainActor (Result<[URL], Error>) -> Void) -> Editor
) {
    do {
        let image = try EditableImage(url: url)
        EditorWindowController.shared.present(size: size) { close in
            editor(image, close) { result in
                complete(result)
                if case .success = result { close() }
            }
        }
    } catch {
        complete(.failure(error))
    }
}

struct EditImageAction: EditorAction {
    var id: String { "edit" }
    var title: String { String(localized: "Edit") }
    var symbol: String? { "slider.horizontal.3" }
    var inputTypes: [UTType] { [.image] }

    @MainActor
    func present(_ url: URL, tint: Color, complete: @escaping @MainActor (Result<[URL], Error>) -> Void) {
        do {
            let image = try EditableImage(url: url)
            EditorWindowController.shared.presentDocument(title: String(localized: "Edit — \(url.lastPathComponent)"),
                                                          size: CGSize(width: 1160, height: 760),
                                                          minSize: CGSize(width: 940, height: 620)) { close in
                FullEditorView(image: image, tint: tint, onClose: close) { result in
                    complete(result)
                    if case .success = result { close() }
                }
            }
        } catch {
            complete(.failure(error))
        }
    }
}

struct AnnotateAction: EditorAction {
    var id: String { "annotate" }
    var title: String { String(localized: "Annotate") }
    var symbol: String? { "pencil.tip.crop.circle" }
    var inputTypes: [UTType] { [.image] }

    @MainActor
    func present(_ url: URL, tint: Color, complete: @escaping @MainActor (Result<[URL], Error>) -> Void) {
        presentImageEditor(url, size: CGSize(width: 460, height: 610), tint: tint, complete: complete) { image, close, finish in
            AnnotateView(image: image, tint: tint, onClose: close, onFinish: finish)
        }
    }
}

struct RedactAction: EditorAction {
    var id: String { "redact" }
    var title: String { String(localized: "Redact") }
    var symbol: String? { "eye.slash" }
    var inputTypes: [UTType] { [.image] }

    @MainActor
    func present(_ url: URL, tint: Color, complete: @escaping @MainActor (Result<[URL], Error>) -> Void) {
        presentImageEditor(url, size: CGSize(width: 440, height: 580), tint: tint, complete: complete) { image, close, finish in
            RedactView(image: image, tint: tint, onClose: close, onFinish: finish)
        }
    }
}

struct TrimVideoAction: EditorAction {
    var id: String { "trim" }
    var title: String { String(localized: "Trim") }
    var symbol: String? { "scissors" }
    var inputTypes: [UTType] { [.movie] }

    @MainActor
    func present(_ url: URL, tint: Color, complete: @escaping @MainActor (Result<[URL], Error>) -> Void) {
        EditorWindowController.shared.present(size: CGSize(width: 560, height: 800)) { close in
            VideoEditorView(url: url, tint: tint, onClose: close) { result in
                complete(result)
                if case .success = result { close() }
            }
        }
    }
}
