//
//  PromptSection.swift
//  MaryBrain
//
//  THE SYSTEM PROMPT, AS NAMED PIECES INSTEAD OF ONE ACCRETING STRING.
//
//  `MaryPrompts.system` was 190 lines appending to a single `var prompt`
//  across nine `+=` sites, four of them inside an `if` or a `for`. Reading it
//  told you the bytes; it never told you what the model receives, in what
//  order, or what any of it costs — so nothing could decide to send less.
//
//  THE SEPARATOR BELONGS TO THE SECTION, and this is the load-bearing
//  decision of the whole design. Today's prompt is a concatenation of pieces
//  that each carry their own lead: "\n\n" for most, a single "\n" between the
//  coding header and its body, "\n- " for every roster line and held mention,
//  a bare " " for the voice's persona and capability, and nothing at all for
//  the opening block. A renderer that supplied a uniform join would produce a
//  DIFFERENT STRING — and the difference is invisible to every
//  `contains`-shaped pin in this tree. Pure concatenation of self-leading
//  sections is what makes the refactor byte-identical BY CONSTRUCTION rather
//  than by inspection.
//
//  ORDERING IS DECLARED, not remembered. The old file defended its order with
//  comments hundreds of lines from the code they governed ("the live text
//  lands LAST on purpose", "IT ENDS ON THE PASSAGE"). `terminal` states that
//  in the type, and `PromptPlan.validate` checks it.
//

import Foundation
import os

/// Every atomic piece either prompt can be built from.
public enum PromptSectionID: String, Sendable, Hashable, CaseIterable, Codable {
    // The static spine of `system()`.
    case identity, clock, spokenRegister, registerSwitch
    case commandKinds, stepwise, confirmation
    // The roster block — all gated on a non-empty plugin list.
    case rosterHeader, rosterFragments, eyesDoctrine, compositionParadigm
    // The canvas twin of `compositionParadigm`, gated on an installed
    // design-capable dynamic application.
    // Configuration, then per-turn perception.
    case projects, ambientNotes
    // THE LEAD PLACE'S LIVE CONTEXT — one header naming it, then its own
    // lines. FOUR SLOTS COLLAPSED INTO THESE TWO: there used to be a coding
    // pair, a writing pair, and a third for "an application the user taught",
    // which between them encoded a belief that Mary ships with some
    // applications compiled in and meets the rest later. She does not. Every
    // place arrives the same way, so every place renders the same way, and the
    // header asks the roster for the name rather than a closed enum.
    case leadHeader, leadSections
    // THE MERGED-WORLDS SECTION: compact per-place lines for places with
    // fresh evidence beside the lead (the ADHD-trait workflow — Sketch,
    // Xcode, Pages, a browser at once). The lead keeps its full section;
    // these are mention-grade context, budgeted by AmbientRanker's co-active
    // constants. Empty (single-place turns) renders nothing, byte-identically.
    case coActiveSections
    case heldFacts

    // The VOICE lane, at coarser grain than `system()` and deliberately so.
    //
    // Nine of `seerInstructions`' pieces are CHILDREN composed inside another
    // piece's template, not siblings: `reachClause` is spliced into the
    // retrieval paragraph's final sentence, and the sight paragraph and the
    // three authority blocks sit inside the live-work frame. Flattening them
    // into sibling sections would move that frame's closing paragraph, which
    // is a byte change and a meaning change — the frame's last words are what
    // tell the model the excerpt is bounded. So each frame is ONE section that
    // composes its own children, exactly as the source does.
    case seerPreamble
    case seerPersonaRead, seerPersonaGrounded, seerPersonaInTurn
    case seerCapability, seerRetrieval, seerRunningActions, seerLiveWork
    // A look fired for THIS turn and nothing is in hand yet — the voice
    // promises the look instead of denying sight. Renders only when the
    // pre-lane look missed its budget; empty on every other pass.
    case seerSightPending
}

/// Sections that may not both render. Membership is checked at render time,
/// so a plan cannot express a contradiction even if its inputs do.
///
/// THE LIVE WORLDS ARE DELIBERATELY NOT IN HERE, and the byte-identity gate
/// is what taught that lesson. Tagging `codingDoctrine` and `writingHeader`
/// as mutually exclusive looks obviously right — `fullSectionsNeverCoexist`
/// pins that they never both appear — but the guarantee lives in
/// `WorkspaceFocusArbiter.sections`, UPSTREAM. `system()` itself has always
/// rendered both when handed both, and the matrix hands it both. Enforcing
/// the invariant here would be a real behavior change wearing a refactor's
/// clothes, and it belongs to whoever decides to make it, with its own test.
public enum PromptExclusiveGroup: String, Sendable, Hashable, CaseIterable {
    /// The voice's three personas — read / grounded / in-turn — which are a
    /// genuine `if / else if / else` in the source and so are exclusive in
    /// fact, not merely in practice.
    case seerPersona
}

/// The ordering doctrine, declared rather than commented.
public struct PromptOrdering: Sendable, Equatable {
    /// Nothing may follow this section's text.
    ///
    /// "The live text lands LAST on purpose: nothing may follow it, or the
    /// model reads the following doctrine as part of the document." Several
    /// sections may DECLARE terminal (they are mutually exclusive); at most
    /// one may RENDER, and it must be last.
    public var terminal: Bool = false
    public static let free = PromptOrdering()
    public static let last = PromptOrdering(terminal: true)
}

/// What became of one section this render.
public enum PromptSectionOutcome: String, Sendable, Equatable, Codable {
    case rendered
    /// The section had nothing to say for these inputs.
    case gatedOut
    /// The plan did not include it.
    case omitted
    /// It lost its exclusive group to a section earlier in the plan.
    case excluded
}

/// One row of the budget waterfall.
public struct PromptSpend: Sendable, Equatable {
    public var id: PromptSectionID
    public var outcome: PromptSectionOutcome
    /// Characters this section contributed, separator included.
    public var chars: Int
    /// One line on why this section exists — shown beside its row in the
    /// debugger, so "why is this 1,038 characters?" has a runtime answer.
    public var rationale: String
}

/// A rendered prompt plus the account of how it was spent.
public struct PromptRender: Sendable, Equatable {
    public var text: String
    /// ONE ENTRY PER SECTION IN THE PLAN, including the ones that rendered
    /// nothing. A waterfall with the zeroes missing cannot answer "why isn't
    /// the held block here?", which is the question it is for.
    public var spend: [PromptSpend]

    public var total: Int { text.count }

    /// `spend` must account for every character of `text`. A dishonest
    /// waterfall is worse than no waterfall; pinned by the plan tests.
    public var isAccounted: Bool {
        spend.reduce(0) { $0 + $1.chars } == text.count
    }
}

/// Everything a section may read. One value for the whole prompt so
/// `PromptSection.render` has one signature and the debugger has one thing to
/// show.
public struct PromptInputs: Sendable {
    public var plugins: [any MaryAdapter] = []
    public var projects: [String: String] = [:]
    /// The lead place's own lines, in full — whatever discipline it holds.
    public var leadContext: [String] = []
    public var ambientNotes: [String] = []
    public var heldFacts: [String] = []
    public var heldMentions: [String] = []
    /// WHO OWNS `leadContext`. Nil exactly when nothing leads.
    ///
    /// A PLACE, NOT AN ENUM CASE. Its predecessor was a closed list of
    /// editors, which could not name an application the user taught Mary — so
    /// a session in one rendered under whichever built-in the enum defaulted
    /// to: a banner naming a product the user did not have open, over that
    /// product's own doctrine.
    public var leadPlace: AmbientPlace?

    /// What the lead header calls the place.
    public var leadPlaceName: String { leadPlace?.displayName ?? "" }
    /// Compact lines for the CO-ACTIVE places beside the lead — the merged
    /// worlds. Defaulted empty (single-place turns), rendered by
    /// `coActiveSections`.
    public var coActiveContext: [String] = []
    /// Plugin owners whose `promptFragment` this turn withholds — the rival
    /// writing worlds a writing lead scoped out of the roster. Computed by
    /// the caller from the same lead/admitted formula the roster uses, so a
    /// fragment never describes tools the schema list does not carry. Empty
    /// (the default) renders every fragment, today's behaviour.
    public var standingDownFragmentOwners: Set<String> = []
    public var now: Date = Date()
    public var timeZone: TimeZone = .current
    public var calendar: Calendar = .current

    // The voice lane's own inputs. `heldFacts`/`heldMentions` above are shared
    // — both lanes render the same store, deliberately differently.
    public var capability: String?
    public var groundedResults: String?
    public var liveWork: [String] = []
    public var liveWorkWorld: LiveWorkWorld = .unled
    public var readPassages: [String] = []
    public var readReport: Bool = false
    /// Labels of routines still running from EARLIER turns.
    ///
    /// It is an INPUT rather than something appended to the finished prompt,
    /// and that is the whole point — see `PromptCatalog.seerRunningActions`.
    public var runningActions: [String] = []
    /// A screen look fired for this very turn with nothing in hand yet.
    public var lookUnderway: Bool = false

    public init(
        plugins: [any MaryAdapter] = [],
        projects: [String: String] = [:],
        leadContext: [String] = [],
        ambientNotes: [String] = [],
        heldFacts: [String] = [],
        heldMentions: [String] = [],
        leadPlace: AmbientPlace? = nil,
        coActiveContext: [String] = [],
        standingDownFragmentOwners: Set<String> = [],
        now: Date = Date(),
        timeZone: TimeZone = .current,
        calendar: Calendar = .current,
        capability: String? = nil,
        groundedResults: String? = nil,
        liveWork: [String] = [],
        liveWorkWorld: LiveWorkWorld = .unled,
        readPassages: [String] = [],
        readReport: Bool = false,
        runningActions: [String] = [],
        lookUnderway: Bool = false
    ) {
        self.runningActions = runningActions
        self.lookUnderway = lookUnderway
        self.capability = capability
        self.groundedResults = groundedResults
        self.liveWork = liveWork
        self.liveWorkWorld = liveWorkWorld
        self.readPassages = readPassages
        self.readReport = readReport
        self.plugins = plugins
        self.projects = projects
        self.leadContext = leadContext
        self.ambientNotes = ambientNotes
        self.heldFacts = heldFacts
        self.heldMentions = heldMentions
        self.leadPlace = leadPlace
        self.coActiveContext = coActiveContext
        self.standingDownFragmentOwners = standingDownFragmentOwners
        self.now = now
        self.timeZone = timeZone
        self.calendar = calendar
    }

    /// The turn's calendar with its time zone applied — every date-formatting
    /// section needs the same one.
    var resolvedCalendar: Calendar {
        var cal = calendar
        cal.timeZone = timeZone
        return cal
    }

    /// CACHED PER (format, timeZone, calendar).
    ///
    /// `DateFormatter()` construction was measured at roughly two thirds of
    /// the entire system-prompt build — five of them per turn across the two
    /// lanes, for three distinct format strings, every one of them
    /// reconstructed from scratch. The whole build is under a millisecond so
    /// this buys nothing a user can feel; it is here because rebuilding an
    /// identical formatter five times a turn is waste, and the cache key is
    /// exactly the three things that decide the output.
    ///
    /// Lock-boxed rather than actor-isolated: sections render synchronously
    /// inside `@Sendable` provider closures called from several actors, which
    /// is the same constraint every other box in this tree solves this way.
    func formatter(_ format: String) -> DateFormatter {
        let key = FormatterKey(
            format: format, timeZone: timeZone.identifier,
            calendar: resolvedCalendar.identifier)
        if let cached = Self.formatterCache.withLock({ $0[key] }) { return cached }
        let formatter = DateFormatter()
        formatter.calendar = resolvedCalendar
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        Self.formatterCache.withLock { $0[key] = formatter }
        return formatter
    }

    struct FormatterKey: Hashable, Sendable {
        var format: String
        var timeZone: String
        var calendar: Calendar.Identifier
    }

    /// `DateFormatter` is not `Sendable`, and handing the same instance to two
    /// threads is a real race — but every read here is a `string(from:)` on a
    /// fully configured formatter, and Foundation documents THAT as thread
    /// safe on a formatter nobody is still mutating. Configuration happens
    /// once, before the instance is ever published to the box.
    private static let formatterCache =
        OSAllocatedUnfairLock<[FormatterKey: DateFormatter]>(initialState: [:])
}

/// One named piece of a prompt.
public struct PromptSection: Sendable {
    public var id: PromptSectionID
    /// Shown beside this section's waterfall row. The long post-mortem stays
    /// as the doc comment above the declaration; this is the part that
    /// survives into the debugger.
    public var rationale: String
    public var ordering: PromptOrdering
    public var exclusive: PromptExclusiveGroup?
    /// Returns this section's contribution INCLUDING its own leading
    /// separator, or "" when it has nothing to say. See the file header.
    public var render: @Sendable (PromptInputs) -> String

    public init(
        id: PromptSectionID,
        rationale: String,
        ordering: PromptOrdering = .free,
        exclusive: PromptExclusiveGroup? = nil,
        render: @escaping @Sendable (PromptInputs) -> String
    ) {
        self.id = id
        self.rationale = rationale
        self.ordering = ordering
        self.exclusive = exclusive
        self.render = render
    }
}

/// The registry of sections, keyed by id.
public struct PromptCatalog: Sendable {
    private let sections: [PromptSectionID: PromptSection]

    public init(_ sections: [PromptSection]) {
        self.sections = Dictionary(
            sections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public subscript(_ id: PromptSectionID) -> PromptSection? { sections[id] }
}
