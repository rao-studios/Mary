//
//  CodeSelectionInteractionTests.swift
//  MaryBrainTests
//
//  THE LANE THAT WAS NEVER DECLARED. `SchemaSignalRuntime.bridgeSelection`
//  has always asked the registry for `interaction.code-selection` whenever
//  the selection's place codes — and no package anywhere declared it, so the
//  guard failed, nil came back, and a real Xcode highlight became NO
//  Interaction at all. Everything downstream (a coding revise primitive,
//  eligibility gates, "this is the comment the user means") was moot until
//  that fact could exist.
//
//  These pin BOTH halves of the fix, because there were two breaks stacked:
//  the missing declaration in `coding.mary`, and — hidden behind it —
//  `selectionValue`'s `guard let document = handoff.scope.documentID`, which
//  nothing in the live selection path has ever satisfied.
//
//  Modeled on `CognitivePrimitivePlacementTests`' shipped-package test: the
//  REAL `coding.mary`, the REAL bridge, a scoped non-shared
//  `SchemaSignalRuntime()` so nothing leaks into a parallel suite, and
//  `withTaughtRoster` rather than a process-wide roster install.
//

import Foundation
import Testing
@testable import MaryAmbient
@testable import MaryBrain
@testable import MaryPlugin

@Suite struct CodeSelectionInteractionTests {

    // MARK: - The declaration

    @Test func codingDeclaresTheCodeSelectionInteractionTheBridgeAsksFor() throws {
        guard let snapshot = try Self.shippedSnapshot() else { return }
        let schema = try #require(
            snapshot.interactionSchema(id: .codeSelection),
            "coding.mary must declare the Interaction bridgeSelection computes for a coding place")

        #expect(schema.valueType == "coding.code-selection")
        #expect(schema.ownership == .sourceOwned)
        #expect(schema.claimPolicy == .oneTurn)
        #expect(schema.privacy == .sensitive)
        #expect(schema.requiredScope.contains(.application))
        #expect(schema.requiredScope.contains(.document))

        // EVERY CHANNEL THE BRIDGE CAN COMPUTE. `bridgeSelection`'s switch
        // picks one of exactly these five strings; a schema missing any one
        // of them silently drops that capture road on the floor, which is the
        // same class of failure as the missing declaration itself.
        let channels = Set(schema.evidence.map(\.channel))
        #expect(channels == [
            "code-buffer-selection",
            "focused-accessibility-selection",
            "application-copy-probe",
            "application-body-range-hydration",
            "workspace-descendant-discovery",
        ])
        // A CLIPPED OR RECOVERED PAYLOAD IS A REFERENT, NEVER AUTHORITY —
        // the same rank ordering `writing.mary`'s own selection schema uses.
        #expect(schema.evidence.first { $0.channel == "code-buffer-selection" }?
            .canAuthorizeMutation == true)
        #expect(schema.evidence.first { $0.channel == "application-copy-probe" }?
            .canAuthorizeMutation == false)

        // The Value type it names has to be present too, or the bridge's
        // `valueTypeSchema(id:)` lookup fails one line later.
        let valueType = try #require(snapshot.valueTypeSchema(id: schema.valueType))
        #expect(valueType.shape == .object)
        #expect(Set(valueType.fields.map(\.name)) == ["context", "source"])
        #expect(valueType.fields.filter(\.required).count == 2)
    }

    // MARK: - The minting

    @Test func aCodingPlacesSelectionMintsTheCodeSelectionInteraction() throws {
        guard let snapshot = try Self.shippedSnapshot() else { return }
        let now = Date()
        let handoff = Self.handoff(
            application: taughtCodingID,
            bundleID: taughtCodingBundleID,
            text: "// tally the results before we hand them back",
            at: now)

        let instance = try withTaughtRoster { () -> RuntimeInteractionInstance in
            #expect(handoff.place.focus == .coding, "the fixture models a coding place")
            let runtime = SchemaSignalRuntime()
            let turn = runtime.snapshotForTurn(
                registry: snapshot, ambientSelection: handoff, at: now)
            return try #require(
                turn.interactions.first { $0.reference.schemaID == .codeSelection },
                "the real bridge turned a live coding selection into a genuine Interaction")
        }

        #expect(instance.evidenceChannel == "focused-accessibility-selection")
        #expect(instance.canAuthorizeMutation)
        #expect(instance.reference.schemaID == .codeSelection)

        // THE PAYLOAD THE SOURCE ACTUALLY PROVED. `application` is always
        // provable and is what the old `documentID` guard was throwing the
        // whole Interaction away for want of a substitute for.
        guard case .object(let payload) = instance.value.value,
              case .object(let context) = payload["context"] ?? .null
        else {
            Issue.record("code-selection payload is not the declared object shape")
            return
        }
        #expect(payload["source"] == .string("// tally the results before we hand them back"))
        #expect(context["application"] == .string(taughtCodingBundleID))
        #expect(context["file"] == nil, "no source proved a document identity here")
    }

    /// THE NEGATIVE THIS MUST NOT DISTURB — the whole point of gating the new
    /// coding primitive on `interaction.code-selection` rather than
    /// `interaction.text-selection`. A prose place's selection still mints
    /// exactly what it always did, through the same bridge, in the same
    /// registry that now also carries the coding schema.
    @Test func aWritingPlacesSelectionStillMintsTextSelectionOnly() throws {
        guard let snapshot = try Self.shippedSnapshot() else { return }
        let now = Date()
        let handoff = Self.handoff(
            application: taughtWritingID,
            bundleID: taughtWritingBundleID,
            text: "the quick brown fox",
            at: now)

        let turn = withTaughtRoster { () -> SchemaSignalTurnSnapshot in
            #expect(handoff.place.focus == .writing)
            return SchemaSignalRuntime().snapshotForTurn(
                registry: snapshot, ambientSelection: handoff, at: now)
        }

        #expect(turn.interactionIDs.contains(.textSelection))
        #expect(!turn.interactionIDs.contains(.codeSelection))
    }

    // MARK: - Fixture

    private static func handoff(
        application: String,
        bundleID: String,
        text: String,
        at now: Date
    ) -> AmbientSelectionHandoff {
        AmbientSelectionHandoff(
            world: .applications,
            application: application,
            applicationID: bundleID,
            processID: 4242,
            text: text,
            editability: .editable,
            capturedAt: now,
            channel: .accessibilityNotification,
            sourceEvidence: .exactElement)
    }

    /// The shipped packages, loaded as the app loads them. Nil (and a skipped
    /// test) when the checkout's `Abilities/` is not reachable from here —
    /// the same guard `CognitivePrimitivePlacementTests` uses.
    private static func shippedSnapshot() throws -> AbilityRuntimeSnapshot? {
        guard let abilities = InstalledPackages.installed() else { return nil }
        var records: [AbilityPackageRecord] = []
        // `writing` for the text-selection half of the split, `coding` for
        // the new half, `window-management` because both name it as a
        // supporting Ability.
        for name in ["coding", "writing", "window-management"] {
            let candidate = abilities.appendingPathComponent("\(name).mary")
            guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
            records.append(AbilityPackageRecord(
                package: try AbilityPackageCodec.load(from: candidate),
                source: .sourceTree,
                sourceURL: candidate,
                validation: .init(),
                rawData: Data()))
        }
        return AbilityRuntimeSnapshot(
            records: records, validation: .init(), adapterManifests: [])
    }
}
