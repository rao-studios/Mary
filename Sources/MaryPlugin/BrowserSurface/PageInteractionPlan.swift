//
//  PageInteractionPlan.swift
//  MaryPlugin
//
//  SEVERAL THINGS ON ONE PAGE, IN ORDER — a login, a search, a form.
//
//  WHY THIS EXISTS WHEN `click_on_page` ALREADY DOES ONE THING. Filling an
//  email, filling a password and pressing sign-in is ONE act to the person
//  asking, and three turns to a model calling three skills. Three turns means
//  three stage leases, three chances for another application to take the
//  screen between steps, and three chances for the model to narrate progress
//  nobody asked to hear. A plan is the same three acts under one lease.
//
//  ⚠️ EVERY STEP NAMES AN ELEMENT, NEVER A COORDINATE, and this is the whole
//  difference from the plan language it descends from. That one carried
//  pointer moves, drags and scrolls at normalized points inside a pinned
//  window — a coordinate lane with a calibration apparatus behind it. Mary
//  refuses pointer steps at compile time and has no such apparatus, and the
//  loss is smaller than it sounds: a point is only meaningful while the page
//  holds still, and the pages worth automating are exactly the ones that
//  reflow. An element survives the reflow; a point does not.
//
//  THE PLAN IS ADMITTED WHOLE BEFORE ANYTHING IS PRESSED. A sequence that
//  will fail at step four should fail before step one — half a login is worse
//  than none, because the user cannot see which half happened.
//
//  IT REPORTS WHAT IT DID, not what it was asked to do. A plan that stops at
//  step three says so and names the step; there is no partial success that
//  reads as success.
//

import Foundation

/// One step. A closed vocabulary — the same verbs the single-act skills
/// expose, because a plan should not be able to do anything a person could
/// not ask for one at a time.
public struct PageInteractionStep: Sendable, Equatable {

    public enum Verb: String, Sendable, Equatable, CaseIterable {
        /// Press a link, button or control.
        case press
        /// Replace a field's contents.
        case fill
        /// Bring something into view without pressing it.
        case reveal
        /// Let the page catch up. The one step that names no element.
        case wait
    }

    public var verb: Verb
    /// The element's label, exactly as `list_page_elements` showed it. Empty
    /// only for `wait`.
    public var target: String
    /// What to type, for `fill`.
    public var text: String?
    /// How long to wait, for `wait`.
    public var seconds: Double?

    public init(verb: Verb, target: String = "", text: String? = nil, seconds: Double? = nil) {
        self.verb = verb
        self.target = target
        self.text = text
        self.seconds = seconds
    }
}

public enum PageInteractionPlan {

    /// SIXTEEN, inherited with its reasoning: long enough for any form a
    /// person would describe in one sentence, short enough that a plan cannot
    /// become a program. A sequence needing more steps than this is a task
    /// the user should watch.
    public static let maximumSteps = 16
    /// A step's wait, bounded at both ends. Zero is a step that does nothing;
    /// more than this is a plan holding the screen while the user waits for
    /// it, unable to see why.
    public static let waitRange: ClosedRange<Double> = 0.05...3.0
    /// What one `fill` may place. A field is not a document; text longer than
    /// this is a paste that belongs in an editor.
    public static let maximumTextBytes = 4096

    public enum Issue: Error, Equatable, Sendable {
        case empty
        case tooManySteps(Int)
        case missingTarget(Int, PageInteractionStep.Verb)
        case missingText(Int)
        case textTooLong(Int, Int)
        case waitOutOfRange(Int, Double)
        /// A `wait` naming a target, or a `press` carrying text — a step whose
        /// fields do not match its verb was written by something that did not
        /// understand the verb, and running it would be a guess about which
        /// half was meant.
        case contradictoryStep(Int, PageInteractionStep.Verb)
        /// A line that is not `verb: what` at all. Its own case rather than
        /// borrowing another's, because "I couldn't read that line" and "that
        /// step contradicts itself" send the author to different places.
        case unreadableLine(Int, String)

        public var spoken: String {
            switch self {
            case .empty:
                return "That plan has no steps in it."
            case .tooManySteps(let count):
                return """
                That's \(count) steps; I'll do up to \(PageInteractionPlan.maximumSteps) \
                at once. Anything longer is worth watching.
                """
            case .missingTarget(let index, let verb):
                return "Step \(index + 1) says \(verb.rawValue) but doesn't say what."
            case .missingText(let index):
                return "Step \(index + 1) fills a field but doesn't say with what."
            case .textTooLong(let index, let bytes):
                return """
                Step \(index + 1) types \(bytes) characters into a field; \
                \(PageInteractionPlan.maximumTextBytes) is the most I'll put in one.
                """
            case .waitOutOfRange(let index, let seconds):
                return String(
                    format: "Step %d waits %.1fs; I'll wait between %.2f and %.0f.",
                    index + 1, seconds,
                    PageInteractionPlan.waitRange.lowerBound,
                    PageInteractionPlan.waitRange.upperBound)
            case .contradictoryStep(let index, let verb):
                return "Step \(index + 1) is a \(verb.rawValue) with fields that don't belong to it."
            case .unreadableLine(let index, let line):
                return """
                I couldn't read step \(index + 1) — "\(line.prefix(40))". Each line is \
                a verb, a colon, and what to act on: \
                \(PageInteractionStep.Verb.allCases.map(\.rawValue).joined(separator: ", ")).
                """
            }
        }
    }

    /// Admit a plan, or say everything wrong with it.
    ///
    /// ALL THE ISSUES, NOT THE FIRST. A model correcting one problem per
    /// round-trip is a model taking four turns to write one plan, and the
    /// checks are cheap enough that there is no reason to ration them.
    public static func validate(_ steps: [PageInteractionStep]) -> [Issue] {
        guard !steps.isEmpty else { return [.empty] }
        guard steps.count <= maximumSteps else { return [.tooManySteps(steps.count)] }

        var issues: [Issue] = []
        for (index, step) in steps.enumerated() {
            let target = step.target.trimmingCharacters(in: .whitespacesAndNewlines)
            switch step.verb {
            case .press, .reveal:
                if target.isEmpty { issues.append(.missingTarget(index, step.verb)) }
                if step.text != nil || step.seconds != nil {
                    issues.append(.contradictoryStep(index, step.verb))
                }
            case .fill:
                if target.isEmpty { issues.append(.missingTarget(index, step.verb)) }
                guard let text = step.text else {
                    issues.append(.missingText(index))
                    continue
                }
                if text.utf8.count > maximumTextBytes {
                    issues.append(.textTooLong(index, text.utf8.count))
                }
                if step.seconds != nil { issues.append(.contradictoryStep(index, .fill)) }
            case .wait:
                if !target.isEmpty || step.text != nil {
                    issues.append(.contradictoryStep(index, .wait))
                }
                guard let seconds = step.seconds else {
                    issues.append(.waitOutOfRange(index, 0))
                    continue
                }
                if !waitRange.contains(seconds) {
                    issues.append(.waitOutOfRange(index, seconds))
                }
            }
        }
        return issues
    }

    // MARK: - Reading a plan the model wrote

    /// Parse the compact line form the Skill's contract describes.
    ///
    /// A LINE PER STEP, `verb: target` — because the alternative is a JSON
    /// schema the model must get exactly right before anything can be said
    /// about whether the PLAN was right, and a malformed brace is a worse
    /// error message than a misspelt verb.
    ///
    ///     press: Sign in
    ///     fill: Email = someone@example.com
    ///     wait: 0.5
    public static func parse(_ raw: String) -> Result<[PageInteractionStep], Issue> {
        var steps: [PageInteractionStep] = []
        for line in raw.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let colon = trimmed.firstIndex(of: ":") else {
                return .failure(.unreadableLine(steps.count, trimmed))
            }
            let verbWord = trimmed[trimmed.startIndex..<colon]
                .trimmingCharacters(in: .whitespaces).lowercased()
            let rest = trimmed[trimmed.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            guard let verb = PageInteractionStep.Verb(rawValue: verbWord) else {
                return .failure(.unreadableLine(steps.count, trimmed))
            }
            switch verb {
            case .wait:
                steps.append(.init(verb: .wait, seconds: Double(rest)))
            case .fill:
                // `target = text`, splitting on the FIRST `=` so a password
                // containing one survives.
                guard let equals = rest.firstIndex(of: "=") else {
                    steps.append(.init(verb: .fill, target: rest))
                    continue
                }
                steps.append(.init(
                    verb: .fill,
                    target: String(rest[rest.startIndex..<equals])
                        .trimmingCharacters(in: .whitespaces),
                    text: String(rest[rest.index(after: equals)...])
                        .trimmingCharacters(in: .whitespaces)))
            case .press, .reveal:
                steps.append(.init(verb: verb, target: rest))
            }
        }
        return steps.isEmpty ? .failure(.empty) : .success(steps)
    }

    /// The authoring contract, for the Skill's description. Written here so
    /// the words the model reads and the grammar this parses cannot drift.
    public static var authoringContract: String {
        """
        One step per line, `verb: what`. Verbs: press, fill, reveal, wait.
        Use labels exactly as list_page_elements showed them.
          press: Sign in
          fill: Email = someone@example.com
          wait: 0.5
        At most \(maximumSteps) steps. Each acts on the page already open; \
        nothing here navigates.
        """
    }
}
