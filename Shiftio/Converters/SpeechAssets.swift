import Foundation
import Observation
import Speech

/// The on-device speech model for the user's language. It's Apple's asset, so it can't ship inside the app;
/// instead it is fetched in the background on first launch, so transcription works at once (and offline).
@MainActor @Observable
final class SpeechAssets {
    enum Status: Equatable {
        case checking, installed, downloading, missing, unsupported
        case failed(String)
    }

    private(set) var status = Status.checking

    func refresh() async {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
            status = .unsupported
            return
        }
        let installed = await SpeechTranscriber.installedLocales
        status = installed.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) } ? .installed : .missing
    }

    func install() async {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
            status = .unsupported
            return
        }
        status = .downloading
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [])
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
            status = .installed
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Called at launch: downloads the model only if it's missing.
    func prepareInBackground() {
        Task {
            await refresh()
            if status == .missing { await install() }
        }
    }
}
