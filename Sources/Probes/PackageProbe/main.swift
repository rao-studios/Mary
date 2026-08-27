//
//  main.swift
//  PackageProbe — `mary-package-probe`
//
//  VALIDATE AND SEAL THE SHIPPED ABILITY PACKAGES.
//
//  A `.mary` file is DATA that decides what Mary can do, so the two things
//  that can be wrong with it are both structural: it says something the
//  schema does not allow, or its digest does not cover what it now says.
//  Both are silent at runtime — a package that fails to decode is a package
//  that quietly is not installed — which is why they get a tool rather than a
//  comment asking people to be careful.
//
//    mary-package-probe check            # decode + validate every package
//    mary-package-probe seal             # recompute digests in place
//
//  SEALING IS A SEPARATE VERB FROM CHECKING, deliberately. `seal` rewrites
//  files; a habit of running it to "see if things are fine" is a habit of
//  rewriting files to see if things are fine.
//

import Foundation
import MaryFoundation

let usage = """
mary-package-probe <command>

commands:
  check   decode and validate every .mary package in Abilities/
  seal    recompute each package's integrity digest, in place
"""

/// The checkout's `Abilities/`, found by walking up from this source file.
func abilitiesDirectory() -> URL {
    var directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // PackageProbe
        .deletingLastPathComponent()   // Probes
        .deletingLastPathComponent()   // Sources
        .deletingLastPathComponent()   // repo root
    directory.appendPathComponent("Abilities", isDirectory: true)
    return directory
}

func packages(in directory: URL) -> [URL] {
    (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil))?
        .filter { $0.pathExtension == "mary" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    print(usage)
    exit(1)
}

let directory = abilitiesDirectory()
let files = packages(in: directory)
guard !files.isEmpty else {
    print("No .mary packages in \(directory.path)")
    exit(1)
}

switch command {
case "seal":
    var sealed = 0
    for file in files {
        do {
            // DECODED WITHOUT VERIFYING, because the digest is the thing being
            // replaced — verifying first would make sealing an edited package
            // impossible, which is the only time anyone needs to seal one.
            let package = try AbilityPackageCodec.load(from: file, verifyIntegrity: false)
            let data = try AbilityPackageCodec.encoded(package)
            try data.write(to: file, options: .atomic)
            sealed += 1
            print("  sealed \(file.lastPathComponent)  (\(data.count) bytes)")
        } catch {
            print("  ✗ \(file.lastPathComponent): \(error)")
            exit(1)
        }
    }
    print("\n\(sealed) package(s) sealed.")

case "check":
    var failures = 0
    var loaded: [MaryAbilityPackage] = []
    for file in files {
        do {
            loaded.append(try AbilityPackageCodec.load(from: file))
        } catch {
            failures += 1
            print("  ✗ \(file.lastPathComponent): \(error.localizedDescription)")
        }
    }
    // VALIDATED AS A GRAPH, not one at a time. Packages reference each other
    // — a dependency, a supporting ability, a skill another package realizes
    // — and half the errors worth catching only exist between two of them.
    let validation = PluginGraphValidator.validate(loaded)
    for package in loaded {
        let file = "\(package.package.id.rawValue).mary"
        do {
            let issues = validation.issues.filter {
                $0.path.hasPrefix(package.package.id.rawValue)
            }
            let errors = issues.filter { $0.severity == .error }
            if errors.isEmpty {
                let skills = package.skills.count
                let operations = package.plugin?.operations.count ?? 0
                var line = "  ✓ \(file)"
                line += "  ability=\(package.ability.id.rawValue)"
                line += "  skills=\(skills)"
                if operations > 0 { line += "  operations=\(operations)" }
                if let surface = package.plugin?.proseSurface {
                    line += "  prose=\(surface.documentNoun.singular)"
                }
                if !issues.isEmpty { line += "  (\(issues.count) note(s))" }
                print(line)
            } else {
                failures += 1
                print("  ✗ \(file)")
                for issue in errors.prefix(6) {
                    print("      \(issue.code) at \(issue.path): \(issue.message)")
                }
            }
        }
    }
    // ISSUES NOBODY CLAIMED. A graph error whose path names no package is
    // still an error, and dropping it because the per-package filter missed
    // it is how a whole class of cross-package problem goes unreported.
    let claimed = Set(loaded.map(\.package.id.rawValue))
    let orphaned = validation.issues.filter { issue in
        issue.severity == .error
            && !claimed.contains(where: issue.path.hasPrefix)
    }
    for issue in orphaned {
        failures += 1
        print("  ✗ (graph) \(issue.code) at \(issue.path): \(issue.message)")
    }
    print("\n\(files.count - failures)/\(files.count) package(s) valid.")
    exit(failures == 0 ? 0 : 1)

default:
    print(usage)
    exit(1)
}
