//
//  InstalledPackagesGate.swift
//  MaryBrainTests
//
//  THE SUITES THAT NEED REAL PACKAGES ON DISK, and how they behave before any
//  are shipped.
//
//  Ability packages are DATA, and three suites here test the machinery that
//  finds, validates and routes them — which means they need real `.mary`
//  files in `Abilities/`, not fixtures. Until those ship, the honest state is
//  "not exercised yet", and this is how a suite says so.
//
//  A SKIP, NOT A DELETION, and not a fixture stand-in either. Deleting them
//  loses the coverage silently; faking the packages would test the fake. A
//  skip that names what is missing is the only one of the three that stays
//  true when the packages arrive.
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
