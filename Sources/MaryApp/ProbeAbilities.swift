//
//  ProbeAbilities.swift
//  Mary
//
//  What the Ability registry actually looks like at boot:
//
//      swift run Mary --probe-abilities [substring]
//
//  WHY THIS EXISTS. A Skill can be perfectly valid, ship in a package that
//  round-trips, pass every schema and routing suite — and still sit BLOCKED in
//  the app, because readiness is a HANDSHAKE between the package's declared
//  contract and the installed adapter's published one. Nothing in the test
//  suites saw that seam, so the first sighting of a mismatch was a red word in
//  Ability Studio with the reason one click away and no way to ask from a
//  terminal.
//
//  This runs the SAME configuration install the app runs at launch, then prints
//  every Skill with its readiness and, when it is not ready, the evaluator's own
//  sentences. It is the answer to "why is this blocked" and to the question
//  underneath it — "is my build stale, or is my contract wrong?"
//

import MaryBrain
import MaryPlugin
import Foundation
import MaryRuntime

enum ProbeAbilities {
    static func shouldRun() -> Bool {
        CommandLine.arguments.contains("--probe-abilities")
    }

    static func start() {
        Task { @MainActor in
            let arguments = CommandLine.arguments
            let filter = arguments.firstIndex(of: "--probe-abilities")
                .flatMap { index -> String? in
                    let next = index + 1
                    guard arguments.count > next, !arguments[next].hasPrefix("--")
                    else { return nil }
                    return arguments[next].lowercased()
                }

            // The app's own boot path — not a hand-built snapshot. A hand-built
            // one would prove the code compiles, which is not the question.
            await MaryRuntime.installBrainConfiguration(projects: [:])
            let snapshot = AbilityLibrary.shared.snapshotEnsuringLoaded()

            print("[abilities] revision \(snapshot.revision.uuidString)")
            print("[abilities] \(snapshot.records.count) package(s), \(snapshot.adapterManifests.count) adapter manifest(s)")
            for issue in snapshot.validation.issues {
                print("[abilities] graph issue: \(issue)")
            }

            let skills = snapshot.skills.filter { skill in
                guard let filter else { return true }
                return skill.skill.id.rawValue.lowercased().contains(filter)
                    || skill.ability.id.rawValue.lowercased().contains(filter)
                    || (skill.skill.invocationName ?? "").lowercased().contains(filter)
            }
            guard !skills.isEmpty else {
                print("[abilities] no Skill matches \(filter ?? "")")
                exit(1)
            }

            var blocked = 0
            for skill in skills.sorted(by: { $0.skill.id.rawValue < $1.skill.id.rawValue }) {
                let readiness = skill.availability.readiness
                if readiness == .blocked { blocked += 1 }
                let adapter = skill.reference.adapterID?.rawValue ?? "—"
                let operation = skill.reference.bindingOperation ?? "—"
                print("""
                [\(label(readiness))] \(skill.skill.id.rawValue) \
                → \(adapter)/\(operation)
                """)
                for reason in skill.availability.reasons {
                    print("          ↳ \(reason)")
                }
                if !skill.availability.missingCapabilities.isEmpty {
                    print("          ↳ missing capabilities: \(skill.availability.missingCapabilities.map(\.rawValue).joined(separator: ", "))")
                }
            }

            // The adapter side of the handshake, because "no installed adapter
            // publishes X" is most often a stale build rather than a bad
            // contract — and those two look identical from Ability Studio.
            if let filter {
                let publishing = snapshot.adapterManifests.filter {
                    $0.adapterID.rawValue.lowercased().contains(filter)
                }
                for manifest in publishing {
                    print("[adapter] \(manifest.adapterID.rawValue) available=\(manifest.isAvailable) operations=\(manifest.operations.map(\.operation).joined(separator: ", "))")
                }
                if publishing.isEmpty {
                    print("[adapter] no installed adapter id contains \(filter) — the build does not carry this Plugin")
                }
            }

            print("[abilities] \(skills.count) shown, \(blocked) blocked")
            exit(blocked == 0 ? 0 : 1)
        }
        RunLoop.main.run()
    }

    private static func label(_ readiness: SkillReadiness) -> String {
        switch readiness {
        case .ready: return "READY  "
        case .partial: return "PARTIAL"
        case .blocked: return "BLOCKED"
        }
    }
}
