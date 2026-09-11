//
//  WindowManagementTurn.swift
//  MaryPlugin
//
//  WHAT: Whether this turn is about a window — utterance plus document place.
//  IN:   runtime (before any adapter) / PluginProseSurfaceSchema.documentNoun
//  OUT:  WindowManagementTurnIntent (targetClasses / invocationName)
//  PIN:  Routing vocabulary, not an integration. Ranking signal, not a gate.
//

import Foundation

/// Classifies the requested target/operation. Does not resolve a window.
/// OUT: roster arbitration (exclude app activation / raw scripting when covered).
public struct WindowManagementTurnIntent: Sendable, Equatable {
    public var targetClasses: Set<String> = []
    public var invocationName: String?
    public var explicitlyRequestsScript = false

    public var targetsWindow: Bool { !targetClasses.isEmpty }
}


/// Document-holding place in play: its noun, and whether the referent points at it.
/// IN: PluginProseSurfaceSchema.documentNoun
public struct WindowManagementDocumentPlace: Sendable, Equatable {
    /// Registration's logical id — used to mint its window target class.
    public var applicationID: String
    /// What this place calls one document, singular ("note", "chapter", "board").
    public var documentNoun: String
    /// Referent already points here, so a bare pronoun has something to mean.
    public var isReferent: Bool

    public init(applicationID: String, documentNoun: String, isReferent: Bool) {
        self.applicationID = applicationID
        self.documentNoun = documentNoun
        self.isReferent = isReferent
    }
}

public enum WindowManagementTurnClassifier {
    /// - Parameter documentPlace: prose surface in play, or nil if none leads.
    public static func classify(
        utterance: String,
        documentPlace: WindowManagementDocumentPlace? = nil
    ) -> WindowManagementTurnIntent {
        let inDocumentPlace = documentPlace != nil
        let referentIsDocumentPlace = documentPlace?.isReferent == true
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
        // Full screen names a window without saying "window". Ranking, not a gate.
        // PIN: read before the targetsWindow guard.
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
        // Numbered "Untitled N" is a window title, not an application habit.
        let namesAnUntitledDocument = tokens.indices.contains { index in
            tokens[index] == "untitled"
                && tokens.index(after: index) < tokens.endIndex
                && Int(tokens[tokens.index(after: index)]) != nil
        }
        // Noun from the package: "the note", "that chapter", "this board".
        let namesTheDocument = documentPlace.map { place in
            let noun = place.documentNoun.lowercased()
            return normalized.contains(" the \(noun) ")
                || normalized.contains(" that \(noun) ")
                || normalized.contains(" this \(noun) ")
        } ?? false
        let refersToTheDocument = referentIsDocumentPlace
            && (normalized.contains(" it ")
                || normalized.contains(" the one ")
                || normalized.contains(" that one ")
                || normalized.contains(" this one "))
        let targetsWindow = namesWindow
            || (inDocumentPlace && namesAnUntitledDocument)
            || namesTheDocument
            || refersToTheDocument
        guard targetsWindow || namesFullScreen else {
            return WindowManagementTurnIntent(
                explicitlyRequestsScript: explicitlyRequestsScript)
        }
        if namesFullScreen, !targetsWindow {
            // Full-screen only: do not also claim macos-application-window.
            return WindowManagementTurnIntent(
                targetClasses: ["window-operation.full-screen"],
                invocationName: leavesFullScreen
                    ? "exit_full_screen" : "make_window_full_screen",
                explicitlyRequestsScript: explicitlyRequestsScript)
        }

        // ASKING FOR A WINDOW THAT DOES NOT EXIST YET.
        //
        // NOT KEYED ON "OPEN". The obvious spelling —
        // `words.contains("open")` — is wrong here and the shipped fixtures say
        // so out loud: "Which note windows are open?" and "What windows do I
        // have open?" are both LIST requests that contain the word. "Open" in
        // English is as often the adjective as the verb.
        //
        // Newness is the thing being asked for, and it has no such ambiguity:
        // a window described as new, another, or fresh is by construction one
        // that is not on screen yet, whatever verb introduced it.
        let namesNew = words.contains("new")
            || words.contains("another")
            || words.contains("fresh")
        let opens = namesNew && targetsWindow

        let lists = words.contains("list")
            || words.contains("which")
            || normalized.contains(" what windows ")
            || normalized.contains(" windows are open ")
        let restores = words.contains("restore")
            || words.contains("unminimize")
            || normalized.contains(" un minimize ")
        // Verb list is a ranking hint, not a dispatch gate.
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
        // Definite plural with nothing singling one out means all of them.
        let pluralWindows = words.contains("windows")
        let allWindows = (words.contains("all") || words.contains("every") || pluralWindows)
            && namesWindow

        let invocationName: String?
        if namesFullScreen {
            invocationName = leavesFullScreen
                ? "exit_full_screen" : "make_window_full_screen"
        } else if opens {
            // Before `lists` and `bringsForward` on purpose: "open a new window"
            // and "bring me up another window" both carry raise vocabulary, and
            // a window that does not exist cannot be raised.
            invocationName = "open_new_window"
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
        // `document-window` is the class a place earns by declaring a prose surface.
        if documentPlace != nil,
           inDocumentPlace || namesAnUntitledDocument || referentIsDocumentPlace {
            targetClasses.insert("document-window")
        }
        // Arity is the model's call: mint both raise classes. List/restore stay exclusive.
        switch invocationName {
        case "make_window_full_screen", "exit_full_screen":
            targetClasses.insert("window-operation.full-screen")
        case "list_app_windows":
            targetClasses.insert("window-operation.list")
        case "restore_window":
            targetClasses.insert("window-operation.restore")
        case "open_new_window":
            targetClasses.insert("window-operation.open-new")
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
