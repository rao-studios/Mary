//
//  PageInteractionPlan.swift
//  MaryFoundation
//
//  WHAT: A short, already-authored sequence of ordinary page gestures, as values.
//  IN:   a model-authored JSON array  OUT: PagePlanExecutor
//  PIN:  VALUE-ONLY, AND THAT IS THE POINT. Nothing here names a browser, a window, a
//        pointer, or a live element. Resolution happens on the other side of this
//        contract, against a page read a moment before each command — so a plan carries
//        WORDS, never handles, and a stale plan cannot press a stale thing.
//        A NAMED TARGET IS RE-RESOLVED PER COMMAND. The executor reads the page again
//        before every step; a target is a phrase to look up, not a coordinate.
//

import Foundation

public enum PageInteractionCommandKind: String, Codable, Hashable, Sendable, CaseIterable {
    case click
    case hover
    case drag
    case keyChord
    case typeText
    case adjust
    case scroll
    case wait
    /// THE ENGINE'S OWN ACT, WHICH NO PLAN MAY NAME.
    ///
    /// PIN: A RECEIPT KIND, NOT A COMMAND. A navigation is receipt rank one —
    /// "the browser went somewhere and stayed" — and it had no kind to be
    /// reported under, so `settle` returned success carrying NO receipt at all
    /// and every `open_location`, `navigate_back`, `reload_page` and `search_web`
    /// reported its work as unproven. Measured across six legs of round 0: the
    /// continuation nudge then asks the model for work that is already done.
    /// It is engine-only for the same reason a browser chord is: a model-authored
    /// plan that could say "navigate" would be steering the browser through a
    /// grammar meant for acting INSIDE a page. `PageInteractionPlanValidator`
    /// refuses it exactly as it refuses a kind that does not exist.
    case navigate

    /// Kinds the engine reports but a plan may not author.
    public static let engineOnly: Set<PageInteractionCommandKind> = [.navigate]

    /// Whether a model-authored plan may name this kind.
    public var isAuthorable: Bool { !Self.engineOnly.contains(self) }
}

/// A unit point in the visible page: (0, 0) is upper-leading, (1, 1) lower-trailing.
/// Admission, not this value, enforces the bounds.
public struct PageInteractionNormalizedPoint: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Where a pointer gesture goes: a phrase to resolve against a fresh page read, or a
/// unit coordinate in the visible page.
public enum PageInteractionPointerLocation: Hashable, Sendable {
    case target(String)
    case point(PageInteractionNormalizedPoint)
}

public enum PageInteractionPointerButton: String, Codable, Hashable, Sendable, CaseIterable {
    case left
    case right
    case center
}

/// The only keys a plan may press.
///
/// PIN: NO LETTERS, NO MODIFIERS, DELIBERATELY. A modified chord inside a page is a
/// BROWSER command — ⌘W closes the tab, ⌘L jumps to the address bar — and an unmodified
/// letter is a SITE shortcut, which this whole discipline exists not to use. What is
/// left is the three keys that mean the same thing on every page there is: commit,
/// dismiss, move on. `NoSiteShortcutsTests` enforces the same rule on Mary's own source;
/// this enforces it on what a model writes.
public enum PageInteractionKey: String, Codable, Hashable, Sendable, CaseIterable {
    case `return`
    case escape
    case tab
}

public struct PageInteractionClickCommand: Hashable, Sendable {
    public var location: PageInteractionPointerLocation
    public var button: PageInteractionPointerButton
    public var count: Int

    public init(
        location: PageInteractionPointerLocation,
        button: PageInteractionPointerButton = .left,
        count: Int = 1
    ) {
        self.location = location
        self.button = button
        self.count = count
    }
}

public struct PageInteractionHoverCommand: Hashable, Sendable {
    public var location: PageInteractionPointerLocation

    public init(location: PageInteractionPointerLocation) {
        self.location = location
    }
}

/// A drag ends at another visible-page point, or at a fraction along its named source —
/// the generic range gesture. Horizontal fractions run leading to trailing.
public enum PageInteractionDragDestination: Hashable, Sendable {
    case point(PageInteractionNormalizedPoint)
    case targetFraction(Double)
}

public struct PageInteractionDragCommand: Hashable, Sendable {
    public var source: PageInteractionPointerLocation
    public var destination: PageInteractionDragDestination
    public var button: PageInteractionPointerButton
    public var durationSeconds: Double

    public init(
        source: PageInteractionPointerLocation,
        destination: PageInteractionDragDestination,
        button: PageInteractionPointerButton = .left,
        durationSeconds: Double
    ) {
        self.source = source
        self.destination = destination
        self.button = button
        self.durationSeconds = durationSeconds
    }
}

public struct PageInteractionKeyChordCommand: Hashable, Sendable {
    public var key: PageInteractionKey

    public init(key: PageInteractionKey) {
        self.key = key
    }
}

public struct PageInteractionTypeTextCommand: Hashable, Sendable {
    /// When present, the executor resolves and clicks this named field before typing.
    /// Nil means type where the focus already is — and the typer still proves the focus
    /// accepts text before it delivers a character.
    public var target: String?
    public var text: String
    /// Press Return afterwards. What "search for X" means in one command.
    public var submit: Bool

    public init(target: String? = nil, text: String, submit: Bool = false) {
        self.target = target
        self.text = text
        self.submit = submit
    }
}

/// What a range may be asked for.
///
/// PIN: NO `value`, `delta`, `increment` OR `decrement`, unlike the AX-driven original.
/// A slider read from PIXELS has no value and no step — only a track and a position
/// along it — so those modes would be a promise this lane cannot keep.
public enum PageInteractionAdjustmentMode: String, Codable, Hashable, Sendable, CaseIterable {
    case minimum
    case maximum
    case fraction
}

public struct PageInteractionAdjustCommand: Hashable, Sendable {
    public var target: String
    public var mode: PageInteractionAdjustmentMode
    /// Present exactly when `mode == .fraction`.
    public var fraction: Double?

    public init(target: String, mode: PageInteractionAdjustmentMode, fraction: Double? = nil) {
        self.target = target
        self.mode = mode
        self.fraction = fraction
    }

    /// The position this command asks for, as a fraction of the track.
    public var resolvedFraction: Double {
        switch mode {
        case .minimum: return 0
        case .maximum: return 1
        case .fraction: return fraction ?? 0
        }
    }
}

public struct PageInteractionScrollCommand: Hashable, Sendable {
    public var deltaX: Double
    public var deltaY: Double
    public var settleSeconds: Double

    public init(deltaX: Double, deltaY: Double, settleSeconds: Double = 0) {
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.settleSeconds = settleSeconds
    }
}

public struct PageInteractionWaitCommand: Hashable, Sendable {
    public var seconds: Double

    public init(seconds: Double) {
        self.seconds = seconds
    }
}

public enum PageInteractionAction: Hashable, Sendable {
    case click(PageInteractionClickCommand)
    case hover(PageInteractionHoverCommand)
    case drag(PageInteractionDragCommand)
    case keyChord(PageInteractionKeyChordCommand)
    case typeText(PageInteractionTypeTextCommand)
    case adjust(PageInteractionAdjustCommand)
    case scroll(PageInteractionScrollCommand)
    case wait(PageInteractionWaitCommand)

    public var kind: PageInteractionCommandKind {
        switch self {
        case .click: return .click
        case .hover: return .hover
        case .drag: return .drag
        case .keyChord: return .keyChord
        case .typeText: return .typeText
        case .adjust: return .adjust
        case .scroll: return .scroll
        case .wait: return .wait
        }
    }

    /// The phrase this command names, when it names one. What a receipt reports and what
    /// the executor re-resolves.
    public var target: String? {
        switch self {
        case .click(let click):
            if case .target(let phrase) = click.location { return phrase }
            return nil
        case .hover(let hover):
            if case .target(let phrase) = hover.location { return phrase }
            return nil
        case .drag(let drag):
            if case .target(let phrase) = drag.source { return phrase }
            return nil
        case .typeText(let typing): return typing.target
        case .adjust(let adjust): return adjust.target
        case .keyChord, .scroll, .wait: return nil
        }
    }
}

public struct PageInteractionPlanCommand: Hashable, Sendable {
    /// The authored array position, kept even when earlier commands were dropped, so a
    /// receipt names the step the author wrote.
    public var sourceIndex: Int
    public var action: PageInteractionAction

    public init(sourceIndex: Int, action: PageInteractionAction) {
        self.sourceIndex = sourceIndex
        self.action = action
    }

    public var kind: PageInteractionCommandKind { action.kind }
}

public struct PageInteractionPlan: Hashable, Sendable {
    public var commands: [PageInteractionPlanCommand]

    public init(commands: [PageInteractionPlanCommand]) {
        self.commands = commands
    }

    /// One command, as a plan. What the single verbs build so that everything — a spoken
    /// click and a model-authored sequence — runs through the same executor.
    public static func single(_ action: PageInteractionAction) -> PageInteractionPlan {
        PageInteractionPlan(commands: [.init(sourceIndex: 0, action: action)])
    }

    public static func of(_ actions: [PageInteractionAction]) -> PageInteractionPlan {
        PageInteractionPlan(
            commands: actions.enumerated().map { .init(sourceIndex: $0.offset, action: $0.element) })
    }
}

/// Stable machine-readable categories. Messages stay prose; callers branch on codes.
public enum PageInteractionPlanIssueCode: String, Codable, Hashable, Sendable, CaseIterable {
    case planTooLarge
    case invalidJSON
    case planMustBeArray
    case emptyPlan
    case tooManyCommands
    case eventBudgetExceeded
    case terminalHover
    case commandMustBeObject
    case missingKind
    case unknownKind
    case unknownField
    case missingField
    case invalidType
    case invalidValue
    case mutuallyExclusiveFields
}

public struct PageInteractionPlanIssue: Codable, Hashable, Sendable {
    /// Nil is a plan-level issue; otherwise the authored array position.
    public var sourceIndex: Int?
    public var code: PageInteractionPlanIssueCode
    public var field: String?
    public var message: String

    public init(
        sourceIndex: Int? = nil,
        code: PageInteractionPlanIssueCode,
        field: String? = nil,
        message: String
    ) {
        self.sourceIndex = sourceIndex
        self.code = code
        self.field = field
        self.message = message
    }

    /// How a refusal names this, with its position.
    public var spoken: String {
        guard let sourceIndex else { return message }
        return "step \(sourceIndex + 1): \(message)"
    }
}

public enum PageInteractionPlanValidationResult: Hashable, Sendable {
    case valid(PageInteractionPlan)
    case invalid([PageInteractionPlanIssue])
}
