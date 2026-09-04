//
//  PackageLayeringTests.swift
//  MaryFoundationTests
//
//  WHAT: Standing graph rules — which library targets may join which graphs.
//  OUT:  Package.swift as text
//  PIN:  A forbidden edge forms no cycle; the compiler will not catch it
//

import Foundation
import Testing

@Suite struct PackageLayeringTests {

    // MARK: - Reading the manifest

    /// The single root manifest, read from disk.
    ///
    /// Throws rather than returning empty if the path is wrong, because most
    /// assertions below are of the form "this text does not appear" and an
    /// empty read satisfies all of them. A layering test that silently stops
    /// reading is worse than no layering test at all.
    static func manifest() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaryFoundationTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        return try String(
            contentsOf: root.appendingPathComponent("Package.swift"),
            encoding: .utf8)
    }

    /// The manifest with `//` comments removed.
    ///
    /// The manifest carries STANDING RULE headers that NAME the things the
    /// rules forbid ("no WhisperKit", "Frigate only through MaryBrain").
    /// Scanning raw text would flag the documentation of a rule as a violation
    /// of it.
    static func code(_ manifest: String) -> String {
        manifest
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let slashes = line.range(of: "//") else { return line }
                return line[line.startIndex..<slashes.lowerBound]
            }
            .joined(separator: "\n")
    }

    /// The body of one `.target(name: "X", …)` / `.testTarget(…)` /
    /// `.executableTarget(…)` block, paren-balanced from the opening `(` to
    /// its match.
    ///
    /// Anchored on the `target(` DECLARATION, not on the name: the manifest
    /// opens with `Package(name: "Mary")`, so searching for the name alone
    /// finds the package itself and then balances across the entire file.
    static func targetBlock(_ manifest: String, named name: String) -> String? {
        let source = code(manifest)
        var searchFrom = source.startIndex
        while let open = source.range(of: "target(", range: searchFrom..<source.endIndex) {
            var depth = 1
            var cursor = open.upperBound
            while cursor < source.endIndex, depth > 0 {
                switch source[cursor] {
                case "(": depth += 1
                case ")": depth -= 1
                default: break
                }
                if depth > 0 { cursor = source.index(after: cursor) }
            }
            guard depth == 0 else { return nil }
            let body = String(source[open.upperBound..<cursor])
            if body.contains("name: \"\(name)\"") { return body }
            searchFrom = cursor
        }
        return nil
    }

    /// Just the `dependencies: [...]` array of a target block, one entry per
    /// element, trimmed. `.product(name: "X", package: "Y")` entries survive
    /// whole so a rule can match on either half.
    static func dependencyNames(_ targetBlock: String) -> [String] {
        guard let open = targetBlock.range(of: "dependencies: [") else { return [] }
        var depth = 1
        var cursor = open.upperBound
        while cursor < targetBlock.endIndex, depth > 0 {
            switch targetBlock[cursor] {
            case "[": depth += 1
            case "]": depth -= 1
            default: break
            }
            if depth > 0 { cursor = targetBlock.index(after: cursor) }
        }
        let body = String(targetBlock[open.upperBound..<cursor])
        // Split on commas that are not inside a nested paren — `.product(name:
        // "X", package: "Y")` is ONE entry, and splitting it in two would let
        // a rule match the package half while missing the product half.
        var entries: [String] = []
        var current = ""
        var parens = 0
        for character in body {
            switch character {
            case "(": parens += 1; current.append(character)
            case ")": parens -= 1; current.append(character)
            case "," where parens == 0:
                entries.append(current); current = ""
            default: current.append(character)
            }
        }
        entries.append(current)
        return entries
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Every library target Mary will have, in layering order. A rule naming a
    /// target absent from the manifest is PENDING, not passing.
    static let plannedTargets = [
        "MaryFoundation", "MaryAmbient", "MaryComputerUse", "MaryPlugin",
        "MaryVoice", "MaryBrain", "MaryTotem", "MaryRuntime", "Mary",
    ]

    // MARK: - The rules

    /// THE PARADIGM STANDS ON THE SCHEMA ALONE.
    ///
    /// This is the rule that makes "accessibility is tier 0" a portable claim
    /// rather than a slogan: the ambient layer — store, tiers, places,
    /// surfaces — must be readable and testable without a model runtime or a
    /// Mac integration behind it. Everything it needs from above arrives as an
    /// injected protocol. A second edge here is a claim that the paradigm is
    /// not portable after all.
    @Test func ambientDependsOnFoundationAlone() throws {
        let manifest = try Self.manifest()
        guard let target = Self.targetBlock(manifest, named: "MaryAmbient") else { return }
        let declared = Self.dependencyNames(target)

        #expect(
            declared.count == 1,
            """
            MaryAmbient declares \(declared.count) dependencies: \(declared). \
            It must declare exactly one — MaryFoundation.
            """)
        #expect(declared.first?.contains("MaryFoundation") == true)
    }

    /// THE MACHINE LAYER STANDS ON THE PARADIGM, AND ON THE ENGINE THAT READS PIXELS.
    ///
    /// MaryComputerUse is the only target that posts an input event, performs
    /// an Accessibility action, or captures pixels. That claim is only worth
    /// making while the layer itself is cheap to reason about: the schema, the
    /// ambient vocabulary it publishes into, the Mac — and VisionAX, which is
    /// where captured pixels become something nameable. An edge to MaryPlugin
    /// would invert the stack — adapters are written against the machine, not
    /// the other way round — and an edge to anything above it would put a model
    /// runtime behind a keystroke.
    ///
    /// VisionAX belongs HERE rather than in a target of its own for two reasons.
    /// It consumes the pixels only this layer may capture, so any other home
    /// would have to reach back through this one anyway. And it replicates this
    /// layer's AX vocabulary BY NAME — AXNodeSnapshot, AXScreenElement — so a
    /// second importer makes those names ambiguous at every use;
    /// `VisionAXSealTests` holds that line inside the module, and the rule
    /// below holds it in the manifest.
    @Test func computerUseDependsOnFoundationAmbientAndVisionAXOnly() throws {
        let manifest = try Self.manifest()
        guard let target = Self.targetBlock(manifest, named: "MaryComputerUse") else { return }
        let declared = Self.dependencyNames(target)

        #expect(
            declared.count == 3,
            """
            MaryComputerUse declares \(declared.count) dependencies: \(declared). \
            It must declare exactly three — MaryFoundation, MaryAmbient and VisionAX.
            """)
        #expect(declared.contains { $0.contains("MaryFoundation") })
        #expect(declared.contains { $0.contains("MaryAmbient") })
        #expect(declared.contains { $0.contains("VisionAX") })
    }

    /// ONLY MARYCOMPUTERUSE NAMES VISIONAX.
    ///
    /// The outer half of the seal: the manifest edge exists in exactly one place,
    /// so no other target can reach the module whose type names collide with ours.
    /// The inner half — that only one DIRECTORY imports it — is
    /// `Tests/MaryComputerUseTests/VisionAXSealTests.swift`.
    @Test func onlyComputerUseNamesVisionAX() throws {
        let manifest = try Self.manifest()
        for name in Self.plannedTargets where name != "MaryComputerUse" {
            guard let target = Self.targetBlock(manifest, named: name) else { continue }
            #expect(
                !target.contains("VisionAX"),
                "\(name)'s target block names VisionAX — only MaryComputerUse may hold that edge.")
        }
    }

    /// ADAPTERS ARE WRITTEN AGAINST THE MACHINE LAYER.
    ///
    /// The edge runs one way and it must exist: MaryPlugin's adapters translate
    /// what a Skill needs into hands and sight. If this edge ever disappears,
    /// the machine code came back into MaryPlugin.
    @Test func pluginDependsOnComputerUse() throws {
        let manifest = try Self.manifest()
        guard let target = Self.targetBlock(manifest, named: "MaryPlugin") else { return }
        #expect(
            Self.dependencyNames(target).contains { $0.contains("MaryComputerUse") },
            "MaryPlugin no longer depends on MaryComputerUse — the machine layer moved back in.")
    }

    /// NOTHING BELOW THE MACHINE LAYER KNOWS IT EXISTS.
    ///
    /// MaryAmbient reads AX for its own selection lane and must keep doing that
    /// on MaryFoundation alone; the day it reaches for MaryComputerUse, the
    /// paradigm stops being portable.
    @Test func nothingBelowComputerUseNamesIt() throws {
        let manifest = try Self.manifest()
        for name in ["MaryFoundation", "MaryAmbient", "MaryVoice"] {
            guard let target = Self.targetBlock(manifest, named: name) else { continue }
            #expect(
                !Self.dependencyNames(target).contains { $0.contains("MaryComputerUse") },
                "\(name) depends on MaryComputerUse — it sits below the machine layer.")
        }
    }

    /// THE VOICE LAYER NEVER LEARNS WHAT ANYTHING MEANS.
    ///
    /// MaryVoice decides WHEN to listen and how a sentence should SOUND — the
    /// VAD's endpoint, the wake word, the speaker floor, which synthesizer
    /// carries a chunk. It must not decide WHAT to say, and the cheapest way
    /// to guarantee that is to deny it the vocabulary: no ambient store, no
    /// places, no abilities. An edge to MaryAmbient here would let a barge-in
    /// rule start consulting what is on screen, and the next person to read
    /// the pipeline would have no way to know it does.
    ///
    /// The one domain type it touches is `BehavioralActionRecord`, which
    /// lives in MaryFoundation and which the pipeline only ever RELAYS —
    /// events pass through the voice layer, they are never composed there.
    @Test func voiceDependsOnFoundationAlone() throws {
        let manifest = try Self.manifest()
        guard let target = Self.targetBlock(manifest, named: "MaryVoice") else { return }
        let declared = Self.dependencyNames(target)

        #expect(
            declared.count == 1,
            """
            MaryVoice declares \(declared.count) dependencies: \(declared). \
            It must declare exactly one — MaryFoundation. Ears and mouth, no meaning.
            """)
        #expect(declared.first?.contains("MaryFoundation") == true)
    }

    /// THE PERCEPTION AND ADAPTER LAYERS STAY OUT OF THE INFERENCE AND
    /// TRANSPORT GRAPHS. Frigate/MLX is consumed only through MaryBrain;
    /// Conduit/gRPC only through MaryTotem.
    @Test func perceptionLayersStayOutOfInferenceAndTransport() throws {
        let manifest = try Self.manifest()
        for name in ["MaryAmbient", "MaryComputerUse", "MaryPlugin", "MaryVoice"] {
            guard let target = Self.targetBlock(manifest, named: name) else { continue }
            if name != "MaryComputerUse" {
                #expect(
                    !target.contains("VisionAX"),
                    "\(name)'s target block names VisionAX — that edge is MaryComputerUse's alone.")
            }
            // VisionAX is deliberately NOT in this list for MaryComputerUse's sake —
            // `onlyComputerUseNamesVisionAX` polices it instead, because one target is
            // supposed to have the edge.
            for forbidden in ["Frigate", "MLX", "Conduit", "grpc", "GRPC", "Fleet"] {
                #expect(
                    !target.contains(forbidden),
                    "\(name)'s target block names \(forbidden). It may not join that graph.")
            }
        }
    }

    /// ONLY MARYBRAIN NAMES FRIGATE.
    ///
    /// Frigate vendors swift-transformers targets (`Hub`, `Tokenizers`,
    /// `Jinja`, `Generation`, `Models`) under their original names. Mary has
    /// no second consumer of those names — which is exactly why it needs no
    /// module-alias map — and that stays true only while one target owns the
    /// edge.
    @Test func onlyBrainNamesFrigate() throws {
        let manifest = try Self.manifest()
        for name in Self.plannedTargets where name != "MaryBrain" {
            guard let target = Self.targetBlock(manifest, named: name) else { continue }
            #expect(
                !target.contains("Frigate"),
                "\(name)'s target block names Frigate — only MaryBrain may hold that edge.")
        }
    }

    /// ONLY MARYBRAIN NAMES FLEET. JSONGate / StructuredSession live behind
    /// MaryBrain; Runtime dials Fleet through MaryTotem's generated facade.
    @Test func onlyBrainNamesFleet() throws {
        let manifest = try Self.manifest()
        for name in Self.plannedTargets where name != "MaryBrain" {
            guard let target = Self.targetBlock(manifest, named: name) else { continue }
            #expect(
                !Self.dependencyNames(target).contains(where: { $0.contains("Fleet") }),
                "\(name) depends on Fleet — only MaryBrain may hold that edge.")
        }
    }

    /// NOTHING NAMES WHISPERKIT.
    ///
    /// Mary transcribes with Apple's SpeechAnalyzer. WhisperKit's real
    /// swift-transformers is what forced Bonnie's five-target module-alias
    /// map; the absence of that dependency is what lets this manifest carry
    /// none. Re-adding WhisperKit means rebuilding the alias wall, and this
    /// test is where that decision surfaces.
    @Test func nothingNamesWhisperKit() throws {
        let manifest = try Self.manifest()
        #expect(
            !Self.code(manifest).contains("WhisperKit"),
            """
            The manifest names WhisperKit. Mary's transcription is SpeechAnalyzer; \
            adding WhisperKit reintroduces a second swift-transformers in the same \
            graph as Frigate's vendored copy, which needs a module-alias map to \
            resolve. Rebuild that map deliberately or drop the dependency.
            """)
    }

    /// CONDUIT AND gRPC ARE CONSUMED ONLY THROUGH MARYTOTEM'S FACADE, AND
    /// MARYTOTEM ONLY BY THE RUNTIME AND THE APP. No other target may import
    /// generated protos.
    @Test func totemIsTheOnlyTransportFacade() throws {
        let manifest = try Self.manifest()
        for name in Self.plannedTargets where name != "MaryTotem" {
            guard let target = Self.targetBlock(manifest, named: name) else { continue }
            for forbidden in ["Conduit", "GRPCCore", "GRPCNIOTransport"] {
                #expect(
                    !target.contains(forbidden),
                    "\(name)'s target block names \(forbidden) — that graph is MaryTotem's alone.")
            }
        }
        for name in Self.plannedTargets where !["MaryRuntime", "Mary", "MaryTotem"].contains(name) {
            guard let target = Self.targetBlock(manifest, named: name) else { continue }
            #expect(
                !Self.dependencyNames(target).contains(where: { $0.contains("MaryTotem") }),
                "\(name) depends on MaryTotem — only MaryRuntime and the app may.")
        }
    }

    /// THE ROSTER, PRINTED. A target arriving without a rule should be seen,
    /// not silently unpoliced; a rule whose subject is still unbuilt should
    /// read as pending rather than green.
    @Test func everyRuleHasASubjectOrIsPending() throws {
        let manifest = try Self.manifest()
        let present = Self.plannedTargets.filter { Self.targetBlock(manifest, named: $0) != nil }
        let pending = Self.plannedTargets.filter { !present.contains($0) }
        print("[layering] present: \(present.joined(separator: ", "))")
        if !pending.isEmpty {
            print("[layering] PENDING (rules not yet exercised): \(pending.joined(separator: ", "))")
        }
        #expect(
            present.contains("MaryFoundation"),
            "MaryFoundation is missing from the manifest — the layering test is reading the wrong file.")
    }
}
