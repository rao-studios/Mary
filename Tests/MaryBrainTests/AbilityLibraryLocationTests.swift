import Foundation
import Testing
@testable import MaryBrain

/// WHERE THE SOURCE-TREE PACKAGES LIVE, found by shape rather than by
/// counting directories.
///
/// THE FAILURE THIS PREVENTS: the repository root used to be derived as
/// "this file's path, minus six components" — six being however deep
/// `AbilityLibrary.swift` happened to sit. Moving that file one directory
/// while tidying would have pointed the source-tree location at a path that
/// does not exist, package loading would have fallen back to whatever stale
/// copy the app bundle carried, and Sketch would have gone quietly wrong in a
/// way that reads as a Sketch bug rather than a moved file.
@Suite struct AbilityLibraryLocationTests {

    @Test func theRepositoryRootIsFoundFromThisTestFile() throws {
        guard let abilities = InstalledPackages.installed() else { return }
        #expect(FileManager.default.fileExists(atPath: abilities.path))
        // REAL PACKAGES ARE THERE — not merely some directory named
        // "Abilities" that happens to exist, which is the whole distinction
        // `holdsAbilityPackages` was written to draw.
        let installed = try FileManager.default
            .contentsOfDirectory(atPath: abilities.path)
            .filter { $0.hasSuffix(".mary") }
        #expect(!installed.isEmpty, "Abilities/ holds no .mary packages")
    }

    /// THE POINT OF THE WHOLE EXERCISE: an arbitrarily deeper home for the
    /// source file resolves to the same root, so files may be reorganized
    /// freely.
    @Test func aDeeperSourceLocationStillResolvesTheSameRoot() throws {
        guard InstalledPackages.installed() != nil else { return }
        let actual = try #require(AbilityLibrary.repositoryRoot(from: #filePath))
        for suffix in [
            "Packages/MaryBrain/Sources/MaryBrain/Abilities/AbilityLibrary.swift",
            "Packages/MaryBrain/Sources/MaryBrain/Abilities/Library/AbilityLibrary.swift",
            "Packages/MaryBrain/Sources/MaryBrain/Abilities/Library/Deeper/Still/AbilityLibrary.swift",
        ] {
            let hypothetical = actual.appendingPathComponent(suffix).path
            #expect(AbilityLibrary.repositoryRoot(from: hypothetical) == actual,
                    "a file at \(suffix) must find the same checkout")
        }
    }

    /// A binary running from an unrelated tree has no source packages, and
    /// says so rather than inventing a directory.
    @Test func anUnrelatedPathResolvesToNothing() {
        #expect(AbilityLibrary.repositoryRoot(
            from: "/private/var/folders/zz/nothing/here/Probe.swift") == nil)
    }
}
