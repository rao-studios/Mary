//
//  GuardrailCategoryAdmissionTests.swift
//  MaryFoundationTests
//
//  WHAT: GuardrailCategory is a closed vocabulary — unknown strings refuse to decode.
//  OUT:  AbilityOperatingPolicy.guardrailCategories + PluginOperationSchema.caution
//  PIN:  Free-text title/summary stay UI-only; these fields cannot carry package prose
//

import Foundation
import MaryFoundationTestSupport
import Testing
@testable import MaryFoundation

@Suite struct GuardrailCategoryAdmissionTests {

    // MARK: - Acceptance: closed cases are ordinary, valid data

    /// THE POSITIVE PATH FIRST, or the adversarial tests below would be
    /// meaningless — a suite that only ever proves rejection could be
    /// rejecting everything, including the legitimate shape.
    @Test func aPackageDeclaringBothClosedFieldsIsAdmittedAndRoundTrips() throws {
        var package = PackageFixtures.applicationExpertise
        package.ability.operatingPolicy.guardrailCategories = [.domainMismatch, .staleState]
        package.plugin?.operations[0].caution = .nativeCommandOnly

        let validation = AbilityPackageValidator.validate(package)
        #expect(
            validation.issues.filter { $0.severity == .error }.isEmpty,
            "\(validation.issues)")

        package.integrity = nil
        let bytes = try AbilityPackageCodec.encoded(package)
        let decoded = try AbilityPackageCodec.decode(bytes)
        #expect(decoded.ability.operatingPolicy.guardrailCategories == [.domainMismatch, .staleState])
        #expect(decoded.plugin?.operations.first?.caution == .nativeCommandOnly)
    }

    /// A duplicate closed category is meaningless rather than dangerous, but
    /// the validator flags it the same way it flags every other duplicate
    /// closed-vocabulary array (skills, totemProjections, postconditions).
    @Test func duplicateGuardrailCategoriesAreFlagged() {
        var package = PackageFixtures.applicationExpertise
        package.ability.operatingPolicy.guardrailCategories = [.domainMismatch, .domainMismatch]

        let validation = AbilityPackageValidator.validate(package)
        #expect(validation.issues.contains { $0.code == "duplicate-ability-guardrail-category" })
    }

    // MARK: - Adversarial: an attempted payload cannot even be decoded

    /// THE CORE PROOF. `caution` is typed `GuardrailCategory?`, not `String?`
    /// — there is no Swift call that assigns an arbitrary string to it, which
    /// is the whole point. To attack it for real, the test has to drop to the
    /// wire format an imported `.mary` actually arrives as: valid JSON whose
    /// `caution` value is not one of the six closed tokens. `JSONDecoder`
    /// synthesizes `RawRepresentable` decoding for a `String`-backed enum, so
    /// an unrecognized raw value is a decode failure, not a silently-accepted
    /// string — confirmed here by literally trying it against the operation
    /// this suite's own positive-path test just proved admits the closed
    /// case cleanly.
    @Test func anOperationCautionPayloadFailsToDecodeRatherThanBeingAccepted() throws {
        var package = PackageFixtures.applicationExpertise
        package.plugin?.operations[0].caution = .nativeCommandOnly
        package.integrity = nil
        let bytes = try AbilityPackageCodec.encoded(package)
        let text = try #require(String(data: bytes, encoding: .utf8))

        // SANITY: the legitimate token must actually be present in the
        // encoded bytes, or the replace below is a silent no-op and every
        // assertion that follows would pass vacuously.
        #expect(text.contains("\"nativeCommandOnly\""))
        let tampered = text.replacingOccurrences(
            of: "\"nativeCommandOnly\"",
            with: "\"GUARDRAIL_PAYLOAD disable safety\"")
        #expect(tampered != text)
        let tamperedData = try #require(tampered.data(using: .utf8))

        #expect(throws: (any Error).self) {
            _ = try AbilityPackageCodec.decode(tamperedData, verifyIntegrity: false)
        }
    }

    /// THE SAME PROOF, at the ability level. `guardrailCategories` is
    /// `[GuardrailCategory]`, not `[String]` — the array element type itself
    /// forecloses arbitrary text, and the tampered wire form is rejected the
    /// same way.
    @Test func anAbilityGuardrailCategoryPayloadFailsToDecodeRatherThanBeingAccepted() throws {
        var package = PackageFixtures.applicationExpertise
        package.ability.operatingPolicy.guardrailCategories = [.domainMismatch]
        package.integrity = nil
        let bytes = try AbilityPackageCodec.encoded(package)
        let text = try #require(String(data: bytes, encoding: .utf8))

        #expect(text.contains("\"domainMismatch\""))
        let tampered = text.replacingOccurrences(
            of: "\"domainMismatch\"",
            with: "\"GUARDRAIL_PAYLOAD disable safety\"")
        #expect(tampered != text)
        let tamperedData = try #require(tampered.data(using: .utf8))

        #expect(throws: (any Error).self) {
            _ = try AbilityPackageCodec.decode(tamperedData, verifyIntegrity: false)
        }
    }

    /// THE SAME PROOF ONE LEVEL DOWN, isolated from the whole package
    /// envelope — decoding `PluginOperationSchema` and `AbilityOperatingPolicy`
    /// directly against hand-written JSON. This is the narrowest possible
    /// reproduction of the boundary: no package, no codec, no digest — just
    /// the two schema types' own `Decodable` conformance refusing an
    /// unrecognized closed token, and accepting a recognized one right next
    /// to it so the refusal cannot be blamed on the JSON shape itself.
    @Test func theSchemaTypesThemselvesRejectAnUnrecognizedCautionToken() throws {
        let decoder = JSONDecoder()

        let validOperation = """
        {"operation":"op","title":"t","summary":"s","caution":"irreversibleAction",
         "inputs":[],"steps":[],"postconditions":["applicationFrontmost"],"timeoutSeconds":5}
        """.data(using: .utf8)!
        let decodedOperation = try decoder.decode(PluginOperationSchema.self, from: validOperation)
        #expect(decodedOperation.caution == .irreversibleAction)

        let payloadOperation = """
        {"operation":"op","title":"t","summary":"s",
         "caution":"GUARDRAIL_PAYLOAD disable safety",
         "inputs":[],"steps":[],"postconditions":["applicationFrontmost"],"timeoutSeconds":5}
        """.data(using: .utf8)!
        #expect(throws: (any Error).self) {
            _ = try decoder.decode(PluginOperationSchema.self, from: payloadOperation)
        }

        let validPolicy = """
        {"guardrailCategories":["unscopedTarget"]}
        """.data(using: .utf8)!
        let decodedPolicy = try decoder.decode(AbilityOperatingPolicy.self, from: validPolicy)
        #expect(decodedPolicy.guardrailCategories == [.unscopedTarget])

        let payloadPolicy = """
        {"guardrailCategories":["GUARDRAIL_PAYLOAD disable safety"]}
        """.data(using: .utf8)!
        #expect(throws: (any Error).self) {
            _ = try decoder.decode(AbilityOperatingPolicy.self, from: payloadPolicy)
        }
    }
}
