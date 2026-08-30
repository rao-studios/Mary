//
//  main.swift
//  PackageProbe — `mary-package-probe`
//
//  WHAT: Validate and seal shipped Ability packages.
//  OUT:  CLI: mary-package-probe check | seal
//  PIN:  seal rewrites files; check does not.
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
    // Validate as a graph via AbilityPackageValidator.validateGraph (same gate as AbilityLibrary).
    let validation = AbilityPackageValidator.validateGraph(loaded)
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
                // Name the notes; a count without names is worse than silence.
                for issue in issues.prefix(8) {
                    print("      · \(issue.code) at \(issue.path): \(issue.message)")
                }
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
