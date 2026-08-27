//
//  KokoroAssets.swift
//  MaryVoice
//
//  Resolves the vendored Kokoro model directory. The assets ship as SwiftPM
//  resources of this package (git-lfs), so the normal home is Bundle.module.
//  When the app is assembled into Mary.app the resource bundle is copied
//  into Contents/Resources — the fallback scan covers that case.
//

import Foundation

public enum KokoroAssets {

    /// The bundled KokoroModels directory, or nil if the resources are missing
    /// (e.g. a checkout without `git lfs pull`).
    public static func modelsDirectory() -> URL? {
        if let url = Bundle.module.url(forResource: "KokoroModels", withExtension: nil),
           looksValid(url) {
            return url
        }
        // App-bundle fallback: Mary_MaryVoice.bundle in Contents/Resources.
        if let resources = Bundle.main.resourceURL {
            let candidates = [
                resources.appendingPathComponent("Mary_MaryVoice.bundle/KokoroModels"),
                resources.appendingPathComponent("KokoroModels"),
            ]
            for url in candidates where looksValid(url) {
                return url
            }
        }
        return nil
    }

    /// True when the directory holds at least a synthesis model and the vocab.
    private static func looksValid(_ dir: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.appendingPathComponent("vocab_index.json").path) else {
            return false
        }
        return TTSConfig.variants.contains { variant in
            fm.fileExists(atPath: dir.appendingPathComponent("\(variant.name).mlmodelc").path)
                || fm.fileExists(atPath: dir.appendingPathComponent("\(variant.name).mlpackage").path)
        }
    }
}
