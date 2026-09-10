//
//  SpeechModelAssets.swift
//  MaryVoice
//
//  WHAT: Is the on-device model for these modules on this Mac? Fetch it if not.
//  IN:   ContinuousSpeechTranscriber / AnalyzerSpeechTranscriber
//  OUT:  installed + reserved model, or SpeechModelAssets.Failure
//

import Foundation
import Speech
import os

enum SpeechModelAssets {

    enum Failure: LocalizedError {
        case localeUnsupported(String)
        case modelDownloading(String)

        var errorDescription: String? {
            switch self {
            case .localeUnsupported(let identifier):
                return "On-device transcription is unavailable for \(identifier)."
            case .modelDownloading(let identifier):
                return "The on-device speech model for \(identifier) is still downloading."
            }
        }
    }

    private static let log = Logger(subsystem: "nyc.rao.mary", category: "voice.assets")

    /// Returns once the model is installed. Throws rather than hang on someone else's download.
    static func ensureInstalled(_ modules: [any SpeechModule], locale: Locale) async throws {
        // `status` is the question "is the model on the machine".
        switch await AssetInventory.status(forModules: modules) {
        case .unsupported:
            throw Failure.localeUnsupported(locale.identifier)
        case .supported:
            // Supported but absent — fetch. Nil request at this status is an OS decline.
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                log.info("downloading the on-device speech model")
                try await request.downloadAndInstall()
            }
            guard await AssetInventory.status(forModules: modules) == .installed else {
                throw Failure.modelDownloading(locale.identifier)
            }
        case .downloading:
            // Someone else already started the download. Refuse rather than hang.
            throw Failure.modelDownloading(locale.identifier)
        case .installed:
            break
        @unknown default:
            break
        }

        // Reserve is best-effort. `false` means "this call did not take a slot",
        // not "unusable" — reservation outlives the process. Never released.
        _ = try? await AssetInventory.reserve(locale: locale)
    }
}
