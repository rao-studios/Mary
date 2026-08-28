import Foundation
import MaryAdapters
import Testing
@testable import MaryBrain

/// WHAT A MODEL CALLS A PARAMETER WHEN IT DOES NOT USE THE DECLARED SPELLING.
///
/// THE FAILURE THIS PINS (live, from a user session): asked to bring the
/// TextEdit window "Untitled 47" forward, the model emitted
/// `{"app":"TextEdit","title":"Untitled 47"}`. The parameter is spelled
/// `window`; `title` is the more natural word and is not wrong. Neither name
/// contains the other, so the substring heuristic could not bridge them, the
/// binding read the miss as `""`, and the user was told
/// `I couldn't find one open window matching ""` — a refusal over vocabulary,
/// reported as a fact about their windows.
///
/// The second half of this suite matters as much as the first: the rescue must
/// never move a value the model placed exactly right.
@Suite struct AbilityArgumentReconcileTests {

    private func parameter(
        _ name: String,
        required: Bool = true,
        aliases: [String] = []
    ) -> ModelSkillSchema.Parameter {
        .init(
            name: name, type: "string", description: "",
            required: required, aliases: aliases)
    }

    // MARK: - The rescue

    @Test func aDeclaredAliasFillsTheDeclaredParameter() {
        let reconciled = AbilityRuntime.reconcile(
            ["app": "TextEdit", "title": "Untitled 47"],
            against: [
                parameter("app", required: false),
                parameter("window", aliases: ["title", "window_title"]),
            ])
        #expect(reconciled["window"] == "Untitled 47")
        // THE ORIGINAL KEY SURVIVES. The receipt shown in the inspector is the
        // model's own canonicalised arguments, and rewriting them there would
        // hide the vocabulary drift this rescue exists to absorb.
        #expect(reconciled["title"] == "Untitled 47")
        #expect(reconciled["app"] == "TextEdit")
    }

    @Test func anAliasMatchesRegardlessOfCase() {
        let reconciled = AbilityRuntime.reconcile(
            ["Title": "Shopping List"],
            against: [parameter("window", aliases: ["title"])])
        #expect(reconciled["window"] == "Shopping List")
    }

    @Test func declarationOrderDecidesBetweenTwoPresentAliases() {
        let reconciled = AbilityRuntime.reconcile(
            ["name": "second", "title": "first"],
            against: [parameter("window", aliases: ["title", "name"])])
        #expect(reconciled["window"] == "first")
    }

    // MARK: - What the rescue must never do

    @Test func aValueThePlacedExactlyRightIsNeverOverwritten() {
        let reconciled = AbilityRuntime.reconcile(
            ["window": "Untitled 9", "title": "Untitled 47"],
            against: [parameter("window", aliases: ["title"])])
        #expect(reconciled["window"] == "Untitled 9")
    }

    /// An alias that is ITSELF a declared parameter belongs to that parameter.
    /// This is the same rule the substring heuristic learned from the live
    /// `fill` / `fill_type` incident, restated for the exact-match path.
    @Test func anAliasThatIsAnotherDeclaredParameterIsNeverBorrowed() {
        let reconciled = AbilityRuntime.reconcile(
            ["name": "Safari"],
            against: [
                parameter("name"),
                // A careless declaration: `window` claims `name` as an alias,
                // but `name` is a parameter in its own right on this Skill.
                parameter("window", aliases: ["name"]),
            ])
        #expect(reconciled["name"] == "Safari")
        #expect(reconciled["window"] == nil)
    }

    @Test func anAbsentAliasLeavesTheParameterAbsent() {
        // The binding's `?? ""` turns absence into an empty string; what this
        // pins is that reconcile does not INVENT a value to hand it.
        let reconciled = AbilityRuntime.reconcile(
            ["app": "TextEdit"],
            against: [parameter("window", aliases: ["title"])])
        #expect(reconciled["window"] == nil)
    }

    // MARK: - The pre-existing heuristic still works

    @Test func theSubstringHeuristicStillRescuesALooseSpelling() {
        let reconciled = AbilityRuntime.reconcile(
            ["filename": "/tmp/notes.md"],
            against: [parameter("file")])
        #expect(reconciled["file"] == "/tmp/notes.md")
    }

    /// The live regression the heuristic's own comment records: a model that
    /// sent `fill` correctly had "blue" copied into every parameter whose name
    /// contained it. Aliases run first now, so this must still hold.
    @Test func theHeuristicStillDoesNotRedistributeAnExactlyPlacedValue() {
        let reconciled = AbilityRuntime.reconcile(
            ["fill": "blue"],
            against: [parameter("fill"), parameter("fill_type"), parameter("fill_stops")])
        #expect(reconciled["fill"] == "blue")
        #expect(reconciled["fill_type"] == nil)
        #expect(reconciled["fill_stops"] == nil)
    }
}
