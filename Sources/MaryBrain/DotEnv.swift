//
//  DotEnv.swift
//  MaryBrain
//
//  Seer's loadDotEnv, ported: parse KEY=VALUE lines into the process
//  environment at boot. Mary's `.env` is gitignored; the README says where
//  to copy TINKER_API_KEY from.
//

import MaryVoice
import Foundation

public enum DotEnv {
    /// The sibling Seer checkout whose `.env` holds the shared keys.
    public static let seerEnvDirectory = "\(NSHomeDirectory())/Documents/rao/repositories/Seer"

    /// Mary's boot loader: the repo's own `.env` first, then the Seer
    /// checkout's as a fallback, never overwriting what is already set — so
    /// the hosted lane works out of the box on this machine without copying
    /// keys between repositories.
    ///
    /// ONE KEY, because there is one hosted engine. The version this descends
    /// from probed two providers' variables and fell back if EITHER was
    /// missing, which meant a machine configured for one of them still went
    /// reading another repository's dotfile every launch.
    public static func loadMaryEnvironment() {
        load()
        if ProcessInfo.processInfo.environment[SeerAuth.apiKeyEnvVar] == nil {
            load(from: seerEnvDirectory, overwrite: false)
        }
    }

    /// Load `.env` from the given directory (default: current working
    /// directory, which is the repo root under `swift run`).
    public static func load(
        from directory: String = FileManager.default.currentDirectoryPath,
        overwrite: Bool = true
    ) {
        let path = (directory as NSString).appendingPathComponent(".env")
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        for line in contents.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq])
            let value = String(trimmed[trimmed.index(after: eq)...])
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            setenv(key, value, overwrite ? 1 : 0)
        }
    }
}

/// The one hosted credential.
///
/// A SECOND AUTH ENUM USED TO SIT BESIDE THIS ONE, for a second cloud
/// provider, and every caller had to know which of the two a given engine
/// wanted. Mary has one hosted engine, so she has one key and one place that
/// answers for it.
public enum SeerAuth {
    public static let apiKeyEnvVar = "SEER_TOKEN"

    /// Resolution order: process env, which `.env` was loaded into at boot.
    /// A MISSING KEY MUST NEVER CRASH THE APP — the engine reports it as an
    /// unreachable server, which is what the user can actually act on.
    public static var apiKey: String? {
        if let key = ProcessInfo.processInfo.environment[apiKeyEnvVar], !key.isEmpty {
            return key
        }
        return nil
    }

    public static var isConfigured: Bool { apiKey != nil }
}
