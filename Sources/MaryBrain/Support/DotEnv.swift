//
//  DotEnv.swift
//  MaryBrain
//
//  WHAT: Parse KEY=VALUE into the process environment at boot.
//  IN:   repo `.env` then Sewn `.env`
//  OUT:  process env
//  PIN:  App never authenticates with SEWN_TOKEN; only the voice probe reads it.
//
import MaryVoice
import Foundation

public enum DotEnv {
    /// The sibling Sewn checkout whose `.env` holds the shared keys.
    public static let sewnEnvDirectory = "\(NSHomeDirectory())/Documents/rao/repositories/Sewn"

    /// The voice probe's static bearer — see the header for why this is a
    /// probe credential and not the app's.
    static let probeTokenKey = "SEWN_TOKEN"

    /// Mary's boot loader: the repo's own `.env` first, then the Sewn checkout's as a fallback, never overwriting what is already set
    public static func loadMaryEnvironment() {
        load()
        if ProcessInfo.processInfo.environment[probeTokenKey] == nil {
            load(from: sewnEnvDirectory, overwrite: false)
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
