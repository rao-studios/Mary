//
//  PluginManagedUIModels.swift
//  MaryBrain
//
//  THE VOCABULARY OF ONE MANAGED-UI TRANSACTION — what can go wrong, what a
//  compiled step looks like, and what a materialized operation binds to.
//
//  These are small because the transaction is. A package declares a bounded
//  sequence of local acts; Mary compiles it against the turn's arguments,
//  brings the target forward, performs the acts, and reports. Pointer
//  coordinates stay normalized until the hands denormalize them against the
//  focused window (or a captured Accessibility frame) at perform time.
//

import Foundation
import MaryFoundation

/// Everything that can stop a managed-UI transaction, each with the sentence
/// Mary says out loud.
///
/// SPOKEN, NOT LOGGED. A refusal the user cannot hear is a silence they will
/// read as a bug in Mary rather than a limit of the recipe, so every case
/// carries a plain sentence naming the thing that could not happen.
enum PluginManagedUIError: LocalizedError, Equatable {
    case applicationNotRunning(String)
    /// MORE THAN ONE PROCESS ANSWERS TO THIS DECLARATION, so there is no
    /// single foreground target.
    ///
    /// A DIFFERENT ANSWER FROM "not running", and the difference is what the
    /// user can do about it: told the application is closed they will open a
    /// third copy of something already open twice. Refusing rather than
    /// picking is the point — enumeration order is not a decision, and the
    /// keystrokes would land in whichever window the OS happened to list
    /// first.
    case applicationAmbiguous(String)
    case activationRefused(String, reason: String?)
    case missingArgument(String)
    /// An argument the operation never declared. REFUSED RATHER THAN IGNORED:
    /// a model that invented a parameter believes it did something, and
    /// dropping it quietly makes the recipe run with the model's intent
    /// missing and nobody told.
    case unknownInput(String)
    case missingInput(String)
    case invalidInput(String)
    case argumentNotANumber(String)
    case argumentOutOfRange(String, minimum: Double?, maximum: Double?)
    /// A step named a key or text the compiled grammar cannot express.
    case unsupportedStep(String)
    /// A pointer step named a coordinate space that this transaction never
    /// captured, or an Accessibility locator that found nothing unique.
    case pointerUnavailable(String)
    case textContainsNewline
    case stepFailed(String)
    case timedOut(seconds: Double)
    case cancelled
    case noTimeRemaining

    var errorDescription: String? {
        switch self {
        case .applicationNotRunning(let app):
            return "\(app) isn't running."
        case .applicationAmbiguous(let app):
            return """
                More than one running \(app) matches this Ability, so I \
                couldn't tell which one you meant.
                """
        case .activationRefused(let app, let reason):
            return reason.map { "I couldn't bring \(app) forward — \($0)" }
                ?? "I couldn't bring \(app) forward."
        case .missingArgument(let name), .missingInput(let name):
            return "That operation needs \(name) and I wasn't given one."
        case .unknownInput(let name):
            return "That operation doesn't take a \(name)."
        case .invalidInput(let name):
            return "\(name) isn't a value that operation accepts."
        case .argumentNotANumber(let name):
            return "\(name) has to be a number."
        case .argumentOutOfRange(let name, let minimum, let maximum):
            switch (minimum, maximum) {
            case (.some(let low), .some(let high)):
                return "\(name) has to be between \(low) and \(high)."
            case (.some(let low), nil):
                return "\(name) has to be at least \(low)."
            case (nil, .some(let high)):
                return "\(name) can be at most \(high)."
            case (nil, nil):
                return "\(name) is out of range."
            }
        case .unsupportedStep(let detail):
            return "That recipe asks for something I can't do: \(detail)."
        case .pointerUnavailable(let detail):
            return "I couldn't aim the pointer: \(detail)."
        case .textContainsNewline:
            return "I can't type a line break as part of that step."
        case .stepFailed(let detail):
            return "A step didn't go through: \(detail)."
        case .timedOut(let seconds):
            return "That didn't finish within \(String(format: "%.1f", seconds)) seconds."
        case .cancelled:
            return "I stopped partway through."
        case .noTimeRemaining:
            return "There wasn't any time left to run that."
        }
    }
}

/// One operation, materialized as a Skill the model can call.
struct PluginManagedUIRuntimeBinding: Sendable {
    let owner: String
    let binding: SkillBinding
}

/// Which package revision materialized a binding — carried into the outcome so
/// a receipt names the exact declaration that acted, not just the application.
struct PluginManagedUIProviderIdentity: Sendable, Equatable {
    let packageDigest: String
}

/// A step with every expression already resolved against the turn's arguments.
///
/// COMPILED BEFORE ANYTHING IS TOUCHED. The whole sequence resolves first, so
/// a recipe whose third step is missing an argument fails before the first
/// keystroke rather than halfway through the user's document.
enum PluginCompiledStep: Sendable, Equatable {
    case keyChord(key: PluginKey, modifiers: [PluginKeyModifier])
    case typeText(String)
    case wait(seconds: Double)
    case rebindFocusedWindow(requiresChange: Bool)
    /// Normalized into the coordinate space named by `space` (`content` is
    /// the focused window). Resolved to screen points only at perform time.
    case pointerMove(x: Double, y: Double, space: String)
    case pointerClick(
        x: Double, y: Double, space: String,
        button: PluginPointerButton, count: Int)
    case pointerDrag(
        fromX: Double, fromY: Double,
        toX: Double, toY: Double, space: String)
    case pointerSquareDrag(
        x: Double, y: Double, side: Double, space: String)
    case scroll(
        x: Double, y: Double, space: String,
        deltaX: Double, deltaY: Double)
    case captureAccessibilityAnchor(
        locator: PluginAccessibilityAnchorLocatorSchema, name: String)

    var spokenName: String {
        switch self {
        case .keyChord: return "a keyboard shortcut"
        case .typeText: return "typing"
        case .wait: return "a pause"
        case .rebindFocusedWindow: return "waiting for a new window"
        case .pointerMove: return "moving the pointer"
        case .pointerClick: return "a click"
        case .pointerDrag, .pointerSquareDrag: return "a drag"
        case .scroll: return "a scroll"
        case .captureAccessibilityAnchor: return "finding a control"
        }
    }
}

/// Which arm of the budget race finished first.
enum PluginManagedUIExecutionRace: Sendable {
    case execution(SkillOutcome)
    case deadline(SkillOutcome)
}
