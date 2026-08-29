//
//  CodeSurfaceAdmissionTests.swift
//  MaryFoundationTests
//
//  THE DECLARATION THAT LETS A CODE EDITOR ANSWER "READ MY BUFFER" — the
//  read-only sibling of `ProseSurfaceAdmissionTests`. Half of that file's
//  cases have no analogue here (no chord, no watch cadence — see
//  `PluginCodeSurfaceSchema`'s header for why); what remains pins the same
//  two families of rule for the same reasons.
//

import Foundation
import MaryFoundationTestSupport
import Testing
@testable import MaryFoundation

@Suite struct CodeSurfaceAdmissionTests {

    private func codes(_ surface: PluginCodeSurfaceSchema) -> [String] {
        var collected: [String] = []
        PluginValidator.validateCodeSurface(surface, root: "plugin") { code, _, _ in
            collected.append(code)
        }
        return collected
    }

    private func paths(_ surface: PluginCodeSurfaceSchema, code wanted: String) -> [String] {
        var collected: [String] = []
        PluginValidator.validateCodeSurface(surface, root: "plugin") { code, path, _ in
            if code == wanted { collected.append(path) }
        }
        return collected
    }

    // MARK: - The shape that should pass

    @Test func aWellFormedSurfaceIsAdmitted() {
        #expect(codes(PackageFixtures.codeSurface).isEmpty)
    }

    // MARK: - Handles

    @Test(arguments: ["", "CD", "c", "1", " C"])
    func aHandlePrefixIsOneUpperCaseLetter(_ prefix: String) {
        var surface = PackageFixtures.codeSurface
        surface.handlePrefix = prefix
        #expect(codes(surface).contains("invalid-code-handle-prefix"))
    }

    // MARK: - Where the text is

    @Test func aSurfaceWithNoEditorRoleIsRefused() {
        var surface = PackageFixtures.codeSurface
        surface.editorRoles = []
        #expect(codes(surface).contains("missing-code-editor-role"))
    }

    /// Descending to a button would find a control where a buffer was
    /// promised — silently, reporting an empty buffer rather than a
    /// misconfiguration.
    @Test func anEditorRoleThatHoldsNoTextIsRefused() {
        var surface = PackageFixtures.codeSurface
        surface.editorRoles = [.button]
        #expect(codes(surface).contains("unsupported-code-editor-role"))
    }

    @Test func aTextFieldIsAcceptedAsAnEditorRole() {
        var surface = PackageFixtures.codeSurface
        surface.editorRoles = [.textArea, .textField]
        #expect(codes(surface).isEmpty)
    }

    @Test func aRepeatedEditorRoleIsRefused() {
        var surface = PackageFixtures.codeSurface
        surface.editorRoles = [.textArea, .textArea]
        #expect(codes(surface).contains("duplicate-code-editor-role"))
    }

    @Test func tooManyEditorRolesAreRefused() {
        var surface = PackageFixtures.codeSurface
        surface.editorRoles = Array(
            repeating: PluginAccessibilityRole.textArea,
            count: PluginValidator.maximumCodeEditorRoles + 1)
        #expect(codes(surface).contains("too-many-code-editor-roles"))
    }

    // MARK: - Budgets

    @Test func aBudgetOfZeroIsRefused() {
        var surface = PackageFixtures.codeSurface
        surface.budgets = .init(ambientExcerptCharacters: 0)
        #expect(codes(surface).contains("invalid-code-budget"))
    }

    /// THE SAME CEILINGS THE PROSE FAMILY USES — a source file earns no
    /// smaller an allowance than a manuscript chapter.
    @Test func theCeilingsMatchTheProseFamilys() {
        #expect(
            PluginValidator.maximumCodeWholeDocumentCharacters
                == PluginValidator.maximumProseWholeDocumentCharacters)
        #expect(
            PluginValidator.maximumCodeRegionCharacters
                == PluginValidator.maximumProseRegionCharacters)
        #expect(
            PluginValidator.maximumCodeAmbientExcerptCharacters
                == PluginValidator.maximumProseAmbientExcerptCharacters)
    }

    @Test func aBudgetOverTheCeilingIsRefusedAtTheRightPath() {
        var surface = PackageFixtures.codeSurface
        surface.budgets = .init(
            wholeDocumentCharacters: PluginValidator.maximumCodeWholeDocumentCharacters + 1)
        #expect(
            paths(surface, code: "invalid-code-budget")
                == ["plugin.codeSurface.budgets.wholeDocumentCharacters"])
    }

    // MARK: - Round trip

    /// The declaration survives the codec byte-for-byte, which is what lets a
    /// package's digest be taken over it.
    @Test func aSurfaceRoundTripsThroughTheCodec() throws {
        let original = PackageFixtures.codeSurface
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(PluginCodeSurfaceSchema.self, from: data)
        #expect(decoded == original)
        #expect(try encoder.encode(decoded) == data)
    }

    /// UNKNOWN KEYS ARE REFUSED, like everywhere else in a `.mary` package —
    /// in particular, `grammar` and `chords`, the two fields
    /// `PluginProseSurfaceSchema` carries that this schema deliberately does
    /// not: a package that tries to smuggle a write-oriented field past a
    /// code surface must be refused, not silently ignored.
    @Test func anUnknownKeyIsRefusedRatherThanIgnored() {
        let json = Data("""
        {
          "handlePrefix": "C",
          "grammar": "prose"
        }
        """.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(PluginCodeSurfaceSchema.self, from: json)
        }
    }

    @Test func aChordsKeyIsRefused() {
        let json = Data("""
        {
          "handlePrefix": "C",
          "chords": {}
        }
        """.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(PluginCodeSurfaceSchema.self, from: json)
        }
    }
}
