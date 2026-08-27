//
//  WindowManagementTurn.swift
//
//  WHETHER THIS TURN IS ABOUT A WINDOW — decided from the words plus two
//  booleans, and nothing else.
//
//  A pure utterance classifier, so it is routing vocabulary rather than an
//  integration. It sits in the kit because the runtime consults it before
//  any adapter is chosen, and the reasoning core must not reach into the
//  Window Management plugin to ask.
//

import Foundation

/// Machine-level interpretation of the narrow window operations implemented
/// by the Window Management Ability. This does not resolve a window (the
/// service still does that exactly once); it classifies the user's requested
/// target/operation so roster arbitration can exclude application activation
/// and raw scripting when a typed window Skill already covers the request.
public struct WindowManagementTurnIntent: Sendable, Equatable {
    public var targetClasses: Set<String> = []
    public var invocationName: String?
    public var explicitlyRequestsScript = false

    public var targetsWindow: Bool { !targetClasses.isEmpty }
}


public enum WindowManagementTurnClassifier {
    public static func classify(
        utterance: String,
        textEditContext: Bool,
        textEditReferent: Bool
    ) -> WindowManagementTurnIntent {
        let tokens = utterance.lowercased().split {
            !$0.isLetter && !$0.isNumber
        }.map(String.init)
        let words = Set(tokens)
        let normalized = " " + tokens.joined(separator: " ") + " "
        let explicitlyRequestsScript = words.contains("applescript")
            || words.contains("osascript")
            || normalized.contains(" run script ")
            || normalized.contains(" run a script ")

        let namesWindow = words.contains("window") || words.contains("windows")
        // FULL SCREEN IS ABOUT A WINDOW WITHOUT EVER SAYING "WINDOW", which is
        // why it is read before the `targetsWindow` guard rather than inside
        // it. "Can you make it full screen" names nothing this classifier
        // recognizes as a target, so every rung below it would decline — and
        // that is exactly what happened live: nothing was minted, nothing was
        // eligible, and the turn ended on "I couldn't work out how to do
        // that."
        //
        // It is a RANKING signal, not a gate. The two full-screen Skills carry
        // no eligibility predicate (`bring-application-forward`'s shape, for
        // its reason), so a phrasing this misses costs a preference rather
        // than a command.
        let namesFullScreen = normalized.contains(" full screen ")
            || words.contains("fullscreen")
            || words.contains("maximize")
            || words.contains("maximise")
        let leavesFullScreen = namesFullScreen
            && (words.contains("exit") || words.contains("leave")
                || words.contains("out") || words.contains("off")
                || words.contains("windowed") || words.contains("unmaximize")
                || normalized.contains(" get out of ")
                || normalized.contains(" back to normal "))
        let namesTextEditTitle = tokens.indices.contains { index in
            tokens[index] == "untitled"
                && tokens.index(after: index) < tokens.endIndex
                && Int(tokens[tokens.index(after: index)]) != nil
        }
        let namesTextEditContainer = textEditContext
            && (normalized.contains(" the note ")
                || normalized.contains(" that note ")
                || normalized.contains(" this note "))
        let refersToTextEditContainer = textEditReferent
            && (normalized.contains(" it ")
                || normalized.contains(" the one ")
                || normalized.contains(" that one ")
                || normalized.contains(" this one "))
        let targetsWindow = namesWindow
            || (textEditContext && namesTextEditTitle)
            || namesTextEditContainer
            || refersToTextEditContainer
        guard targetsWindow || namesFullScreen else {
            return WindowManagementTurnIntent(
                explicitlyRequestsScript: explicitlyRequestsScript)
        }
        if namesFullScreen, !targetsWindow {
            // NOTHING BUT THE FULL-SCREEN SIGNAL. The other window classes are
            // deliberately withheld: the user named no window, so claiming
            // `macos-application-window` would make the raise and restore
            // Skills eligible for a phrase that never asked for them.
            return WindowManagementTurnIntent(
                targetClasses: ["window-operation.full-screen"],
                invocationName: leavesFullScreen
                    ? "exit_full_screen" : "make_window_full_screen",
                explicitlyRequestsScript: explicitlyRequestsScript)
        }

        let lists = words.contains("list")
            || words.contains("which")
            || normalized.contains(" what windows ")
            || normalized.contains(" windows are open ")
        let restores = words.contains("restore")
            || words.contains("unminimize")
            || normalized.contains(" un minimize ")
        // THE VERB LIST IS A RANKING SIGNAL NOW, NOT A GATE — which is what
        // lets it be generous. It used to be the only thing making three of
        // the five window Skills eligible at DISPATCH, so a verb it had never
        // heard of ("pull it up", "focus the window") produced a refusal
        // rather than a missing preference. `AbilityRuntime` no longer enforces
        // routing at dispatch, so a miss here costs the model a hint instead of
        // costing the user their command.
        let bringsForward = words.contains("bring")
            || words.contains("raise")
            || words.contains("foreground")
            || words.contains("front")
            || words.contains("forward")
            || words.contains("up")
            || words.contains("pull")
            || words.contains("focus")
            || words.contains("surface")
            || words.contains("activate")
            || words.contains("reveal")
            || words.contains("unhide")
            || words.contains("top")
            || normalized.contains(" to the front ")
            || normalized.contains(" in front ")
            || (words.contains("show") && targetsWindow)
            || (words.contains("switch") && targetsWindow)
        // THE PLURAL IS THE QUANTIFIER. This required the literal word "all",
        // so "bring the TextEdit WINDOWS forward" chose the singular
        // operation, minted `window-operation.bring-one`, and then refused
        // the model's entirely reasonable `bring_all_windows_forward` with
        // "does not match this turn's source and routing context" — a refusal
        // over phrasing rather than meaning. A definite plural with nothing
        // singling one out means all of them, which is how a person says it.
        let pluralWindows = words.contains("windows")
        let allWindows = (words.contains("all") || words.contains("every") || pluralWindows)
            && namesWindow

        let invocationName: String?
        if namesFullScreen {
            invocationName = leavesFullScreen
                ? "exit_full_screen" : "make_window_full_screen"
        } else if lists {
            invocationName = "list_app_windows"
        } else if restores {
            invocationName = "restore_window"
        } else if allWindows && bringsForward {
            invocationName = "bring_all_windows_forward"
        } else if bringsForward {
            invocationName = "bring_window_forward"
        } else {
            invocationName = nil
        }

        var targetClasses: Set<String> = ["macos-application-window"]
        if textEditContext || namesTextEditTitle || textEditReferent {
            targetClasses.insert("textedit-window")
        }
        // ARITY IS THE MODEL'S CALL, not the classifier's. Minting exactly one
        // of the two raise classes made "bring the TextEdit windows forward"
        // eligible for the singular Skill and ineligible for the plural one —
        // a distinction drawn from a plural `s` and then enforced. They are the
        // same effect family at different arity and already share the
        // `foreground-stage` conflict group, so the arbitrator still ranks
        // them; `invocationName` below still carries the single best guess.
        //
        // A read is NOT a raise, so listing and restoring stay exclusive.
        switch invocationName {
        case "make_window_full_screen", "exit_full_screen":
            targetClasses.insert("window-operation.full-screen")
        case "list_app_windows":
            targetClasses.insert("window-operation.list")
        case "restore_window":
            targetClasses.insert("window-operation.restore")
        case "bring_all_windows_forward", "bring_window_forward":
            targetClasses.insert("window-operation.bring-all")
            targetClasses.insert("window-operation.bring-one")
        default:
            break
        }
        return WindowManagementTurnIntent(
            targetClasses: targetClasses,
            invocationName: invocationName,
            explicitlyRequestsScript: explicitlyRequestsScript)
    }
}
