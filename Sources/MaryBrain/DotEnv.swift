//
//  DotEnv.swift
//  MaryBrain
//
//  Seer's loadDotEnv, ported: parse KEY=VALUE lines into the process
//  environment at boot. Mary's `.env` is gitignored.
//
//  WHAT SEER_TOKEN IS, AND IS NOT. The app never authenticates with it —
//  every Seer request (chat, realtime, TTS, Totem) rides a Bearer token
//  minted by `SeerSession`'s account sign-in, which runs by itself at boot
//  with the admin account. The one reader of SEER_TOKEN is the standalone
//  voice probe, which has no session to mint from and takes a static bearer
//  from the environment instead. An enum named `SeerAuth` used to stand
//  here presenting the token as "the one hosted credential", and two
//  Settings rows rendered its presence as the hosted lane's health — telling
//  people to go edit a dotfile the app never reads, while the actual
//  requirement, being signed in, went unreported.
//

import MaryVoice
import Foundation

public enum DotEnv {
    /// The sibling Seer checkout whose `.env` holds the shared keys.
    public static let seerEnvDirectory = "\(NSHomeDirectory())/Documents/rao/repositories/Seer"

    /// The voice probe's static bearer — see the header for why this is a
    /// probe credential and not the app's.
    static let probeTokenKey = "SEER_TOKEN"

    /// Mary's boot loader: the repo's own `.env` first, then the Seer
    /// checkout's as a fallback, never overwriting what is already set — so
    /// the probes work out of the box on this machine without copying keys
    /// between repositories.
    ///
    /// ONE KEY, because there is one hosted engine. The version this descends
    /// from probed two providers' variables and fell back if EITHER was
    /// missing, which meant a machine configured for one of them still went
    /// reading another repository's dotfile every launch.
    public static func loadMaryEnvironment() {
        load()
        if ProcessInfo.processInfo.environment[probeTokenKey] == nil {
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
