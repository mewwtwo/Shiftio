import Foundation

/// All actions that can be placed in a ring, keyed by id.
enum ActionRegistry {
    static let all: [any FileAction] = {
        var actions: [any FileAction] = []
        actions += ImageFormat.allCases.map { ConvertToImageAction(format: $0) as any FileAction }
        actions += DocumentFormat.allCases.map { ConvertToDocumentAction(format: $0) as any FileAction }
        actions += [ConvertMediaAction(format: .mp4)] as [any FileAction]
        actions += [ConvertAudioAction(format: nil)] as [any FileAction]
        actions += AudioFormat.allCases.map { ConvertAudioAction(format: $0) as any FileAction }
        actions += [TranscribeAction(format: .txt), TranscribeAction(format: .srt)] as [any FileAction]
        actions += [ImagesToPDFAction(), CompressAction(), StripMetadataAction(), RemoveBackgroundAction()] as [any FileAction]
        actions += [MergePDFAction(), ZipAction()] as [any FileAction]
        actions += [CropAction(), AddBackgroundAction(), EditImageAction(), AnnotateAction(), RedactAction(), TrimVideoAction(), FileInfoAction()] as [any FileAction]
        actions += ControlAction.tiles as [any FileAction]
        return actions
    }()

    private static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    /// Built-in actions by id, plus the ones the user adds: `shortcut:<name>` and `app:<bundle id>`.
    static func action(_ id: String) -> (any FileAction)? {
        if let action = byID[id] { return action }
        if id.hasPrefix("shortcut:") { return ShortcutAction(name: String(id.dropFirst("shortcut:".count))) }
        if id.hasPrefix("app:") { return AppAction(bundleID: String(id.dropFirst("app:".count))) }
        return nil
    }
}
