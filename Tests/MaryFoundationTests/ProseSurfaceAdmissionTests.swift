//
//  ProseSurfaceAdmissionTests.swift
//  MaryFoundationTests
//
//  THE DECLARATION THAT REPLACES AN APPLICATION-SPECIFIC READER.
//
//  A `proseSurface` block is how a package says where its application keeps
//  editable text, so that Mary's one generic prose adapter can read and write
//  it without a single Swift file naming that application. Everything this
//  file pins falls into two groups.
//
//  COSTS THE USER DID NOT ASK FOR. A watch cadence wakes the machine on a
//  timer and an ambient excerpt is charged to the prompt budget on every turn
//  whether or not anyone asked about that document. Neither cost is visible to
//  the person paying it, so the package proposes and the validator bounds.
//
//  THINGS THAT WOULD FAIL LATER AND CONFUSINGLY. A handle prefix that is two
//  characters, a chord with no modifier, an editor role that holds no text —
//  each of these decodes fine and then misbehaves at the worst possible
//  moment: mid-sentence, in the user's document. Refusing them at admission
//  turns "Mary typed a random letter into my essay" into "this package is
//  malformed."
//

import Foundation
import MaryFoundationTestSupport
import Testing
@testable import MaryFoundation

@Suite struct ProseSurfaceAdmissionTests {

    /// Collects the error codes a surface produces, so each test can name the
    /// one refusal it is about.
    private func codes(_ surface: PluginProseSurfaceSchema) -> [String] {
        var collected: [String] = []
        PluginValidator.validateProseSurface(surface, root: "plugin") { code, _, _ in
            collected.append(code)
        }
        return collected
    }

    private func paths(_ surface: PluginProseSurfaceSchema, code wanted: String) -> [String] {
        var collected: [String] = []
        PluginValidator.validateProseSurface(surface, root: "plugin") { code, path, _ in
            if code == wanted { collected.append(path) }
        }
        return collected
    }

    // MARK: - The shape that should pass

    @Test func aWellFormedSurfaceIsAdmitted() {
        #expect(codes(PackageFixtures.proseSurface).isEmpty)
    }

    // MARK: - Handles

    /// A handle prefix becomes a spoken token. "[W2]" means one window per
    /// session or it means nothing.
    @Test(arguments: ["", "WD", "w", "1", " W"])
    func aHandlePrefixIsOneUpperCaseLetter(_ prefix: String) {
        var surface = PackageFixtures.proseSurface
        surface.handlePrefix = prefix
        #expect(codes(surface).contains("invalid-prose-handle-prefix"))
    }

    // MARK: - Where the text is

    @Test func aSurfaceWithNoEditorRoleIsRefused() {
        var surface = PackageFixtures.proseSurface
        surface.editorRoles = []
        #expect(codes(surface).contains("missing-prose-editor-role"))
    }

    /// Descending to a button would find a control where a document was
    /// promised — and would do it silently, reporting an empty document rather
    /// than a misconfiguration.
    @Test func anEditorRoleThatHoldsNoTextIsRefused() {
        var surface = PackageFixtures.proseSurface
        surface.editorRoles = [.button]
        #expect(codes(surface).contains("unsupported-prose-editor-role"))
    }

    @Test func aTextFieldIsAcceptedAsAnEditorRole() {
        var surface = PackageFixtures.proseSurface
        surface.editorRoles = [.textArea, .textField]
        #expect(codes(surface).isEmpty)
    }

    @Test func aRepeatedEditorRoleIsRefused() {
        var surface = PackageFixtures.proseSurface
        surface.editorRoles = [.textArea, .textArea]
        #expect(codes(surface).contains("duplicate-prose-editor-role"))
    }

    // MARK: - The noun Mary says out loud

    @Test(arguments: ["", " note", "note ", String(repeating: "n", count: 40)])
    func aDocumentNounIsOneShortCleanWord(_ noun: String) {
        var surface = PackageFixtures.proseSurface
        surface.documentNoun = .init(singular: noun, plural: "notes")
        #expect(codes(surface).contains("invalid-prose-document-noun"))
    }

    // MARK: - Chords

    /// THE MOST CONFUSING POSSIBLE FAILURE. A chord with no modifier is not a
    /// command — it is a character, typed into whatever has focus. The user
    /// sees Mary put a stray letter in their document and has no way to guess
    /// why.
    @Test func aChordWithoutAModifierIsRefused() {
        var surface = PackageFixtures.proseSurface
        surface.chords = [.newDocument: .init(key: .n, modifiers: [])]
        #expect(codes(surface).contains("unmodified-prose-chord"))
    }

    @Test func aChordWithARepeatedModifierIsRefused() {
        var surface = PackageFixtures.proseSurface
        surface.chords = [.newDocument: .init(key: .n, modifiers: [.command, .command])]
        #expect(codes(surface).contains("duplicate-prose-chord-modifier"))
    }

    @Test func declaringNoChordsIsFine() {
        var surface = PackageFixtures.proseSurface
        surface.chords = [:]
        #expect(codes(surface).isEmpty)
    }

    // MARK: - Cadence

    @Test func aCadenceFasterThanTheFloorIsRefused() {
        var surface = PackageFixtures.proseSurface
        surface.watch = .init(activeSeconds: 0.05, idleSeconds: 10)
        #expect(codes(surface).contains("invalid-prose-watch-cadence"))
    }

    @Test func anUnboundedCadenceIsRefused() {
        var surface = PackageFixtures.proseSurface
        surface.watch = .init(activeSeconds: .infinity, idleSeconds: 10)
        #expect(codes(surface).contains("invalid-prose-watch-cadence"))
    }

    /// Inverted, the pair says "look harder once the user has stopped caring",
    /// which is the opposite of what the two numbers exist to express.
    @Test func anIdleCadenceBusierThanTheActiveOneIsRefused() {
        var surface = PackageFixtures.proseSurface
        surface.watch = .init(activeSeconds: 10, idleSeconds: 2)
        #expect(codes(surface).contains("inverted-prose-watch-cadence"))
    }

    // MARK: - Budgets

    @Test func aBudgetOfZeroIsRefused() {
        var surface = PackageFixtures.proseSurface
        surface.budgets = .init(ambientExcerptCharacters: 0)
        #expect(codes(surface).contains("invalid-prose-budget"))
    }

    /// THE ONE BUDGET THAT IS SPENT UNINVITED. A whole-document read is
    /// something the user asked for; an ambient excerpt rides along on every
    /// turn. So its ceiling is much lower than the others, and this pins that
    /// the difference is real rather than incidental.
    @Test func theAmbientExcerptIsBoundedFarBelowARequestedRead() {
        #expect(
            PluginValidator.maximumProseAmbientExcerptCharacters
                < PluginValidator.maximumProseWholeDocumentCharacters / 10)

        var surface = PackageFixtures.proseSurface
        surface.budgets = .init(
            ambientExcerptCharacters: PluginValidator.maximumProseAmbientExcerptCharacters + 1)
        #expect(
            paths(surface, code: "invalid-prose-budget")
                == ["plugin.proseSurface.budgets.ambientExcerptCharacters"])
    }

    // MARK: - Round trip

    /// The declaration survives the codec byte-for-byte, which is what lets a
    /// package's digest be taken over it.
    @Test func aSurfaceRoundTripsThroughTheCodec() throws {
        let original = PackageFixtures.proseSurface
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(PluginProseSurfaceSchema.self, from: data)
        #expect(decoded == original)
        #expect(try encoder.encode(decoded) == data)
    }

    /// UNKNOWN KEYS ARE REFUSED, like everywhere else in a `.mary` package.
    /// Ignored bytes would also be absent from the verified digest, which is
    /// how a tampered package could carry something a reader never saw.
    @Test func anUnknownKeyIsRefusedRatherThanIgnored() {
        let json = Data("""
        {
          "handlePrefix": "W",
          "documentNoun": {"singular": "note", "plural": "notes"},
          "readerCommand": "/bin/cat"
        }
        """.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(PluginProseSurfaceSchema.self, from: json)
        }
    }

    /// AN OMITTED SECTION STAYS OMITTED. The digest is taken over these exact
    /// bytes, so an encoder that helpfully wrote `"chords": {}` would change
    /// the digest of every package that declares none.
    @Test func anOmittedChordSetDoesNotAppearInTheEncoding() throws {
        var surface = PackageFixtures.proseSurface
        surface.chords = [:]
        let data = try JSONEncoder().encode(surface)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("chords"))
    }
}
