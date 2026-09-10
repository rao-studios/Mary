//
//  InstalledPackagesGate.swift
//  MaryBrainTests
//
//  WHAT: Path to checkout Abilities/, or skip honestly when none are shipped.
//  OUT:  InstalledPackages.installed()
//

import Foundation
import Testing
@testable import MaryBrain

enum InstalledPackages {
    /// The checkout's `Abilities/` directory, or nil when it holds no
    /// packages yet.
    static var root: URL? {
        AbilityLibrary.repositoryRoot(from: #filePath)?
            .appendingPathComponent("Abilities", isDirectory: true)
    }

    /// The `Abilities/` directory, or nil with a PENDING line printed.
    ///
    /// PRINTED, NOT SILENT. swift-testing has no skip, so a gate like this is
    /// an early return — and an early return is indistinguishable from a
    /// passing test, which is the one thing a gate must never look like. The
    /// line is the same device `PackageLayeringTests` uses for a rule whose
    /// subject has not landed: the suite says out loud that it did not run.
    static func installed(
        _ subject: String = #function, file: String = #filePath
    ) -> URL? {
        if let root { return root }
        print("[packages] PENDING (no .mary packages in Abilities/ yet): \(subject)")
        return nil
    }
}
