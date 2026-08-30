//
//  KokoroAssets.swift
//  MaryVoice
//
//  WHAT: Resolve vendored KokoroModels directory (Bundle.module, then app bundle).
//  IN:   KokoroEngine.loadModels
//  OUT:  models directory URL
//

import Foundation

public enum KokoroAssets {

    /// Bundled KokoroModels, or nil if resources are missing (no git lfs pull).
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
