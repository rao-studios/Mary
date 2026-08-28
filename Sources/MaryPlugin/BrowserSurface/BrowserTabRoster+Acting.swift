//
//  BrowserTabRoster+Acting.swift
//  MaryPlugin
//
//  SWITCHING AND CLOSING TABS — by identity, and proved afterwards.
//
//  Every act here re-reads the strip first and resolves against what is there
//  NOW, then presses an element rather than a position. That is the whole
//  precision argument for the AX road over the Apple-Event one: an index is
//  resolved by counting, and the count moves under a turn whenever a tab
//  opens or closes; an element is the tab.
//
//  AND EVERY ACT IS CONFIRMED. A browser accepts a press and may do nothing
//  with it — `PageElementActions.press` exists because web controls do
//  exactly that. So an act that cannot show the roster moved reports that it
//  could not, rather than reporting the press it successfully sent.
//

import AppKit
import ApplicationServices
import Foundation
import MaryFoundation

public extension BrowserTabRoster {

    /// Naming a tab: what the user said, resolved against what is on screen.
    enum Target: Equatable {
        /// "the third tab" — 1-based, resolved to an element at read time.
        case ordinal(Int)
        /// "the GitHub one" — matched against tab names.
        case named(String)
        /// The tab already on screen.
        case current
    }

    enum Outcome: Equatable {
        case switched(to: String)
        case closed(String)
        /// Nothing matched. Carries what WAS there, so the caller can say so
        /// rather than shrugging.
        case noSuchTab(offered: [String])
        /// More than one thing matched and picking would be a guess. Carries
        /// the rivals, so the refusal can name them — the Xcode doctrine.
        case ambiguous(rivals: [String])
        /// The strip could not be found at all. Distinct from "no such tab":
        /// this is Mary failing to read, not the user naming something absent.
        case noStrip
        /// The press was delivered and the roster did not move.
        case didNotTake(String)
    }

    // MARK: - Resolving

    enum Resolution: Equatable {
        case one(Tab)
        /// Carries the outcome the caller should report verbatim — the
        /// refusal is composed here, where the rivals are in hand.
        case refused(Outcome)
    }

    /// THE RESOLUTION LADDER, pure. Ordinal, then exact name, then
    /// containment, then an ambiguity refusal that names its rivals, then an
    /// honest miss.
    ///
    /// CONTAINMENT IS LAST AND MUST BE UNIQUE. A browser truncates a long tab
    /// name to fit the strip, so exact matching alone fails on precisely the
    /// tabs a person is most likely to name by a fragment. But a fragment
    /// matching three tabs is a question, not an answer.
    static func resolve(_ target: Target, in tabs: [Tab]) -> Resolution {
        guard !tabs.isEmpty else { return .refused(.noStrip) }

        switch target {
        case .current:
            guard let current = tabs.first(where: { $0.isCurrent == true }) else {
                // Nothing said which is current — the `windowTitle` signal's
                // documented weakness. Naming the tabs is more use than
                // guessing the first one.
                return .refused(.ambiguous(rivals: tabs.map(\.name)))
            }
            return .one(current)

        case .ordinal(let ordinal):
            guard let hit = tabs.first(where: { $0.ordinal == ordinal }) else {
                return .refused(.noSuchTab(offered: tabs.map(\.name)))
            }
            return .one(hit)

        case .named(let spoken):
            let wanted = spoken.lowercased().trimmingCharacters(in: .whitespaces)
            guard !wanted.isEmpty else {
                return .refused(.noSuchTab(offered: tabs.map(\.name)))
            }
            let exact = tabs.filter { $0.name.lowercased() == wanted }
            if exact.count == 1 { return .one(exact[0]) }
            if exact.count > 1 { return .refused(.ambiguous(rivals: exact.map(\.name))) }

            let containing = tabs.filter { $0.name.lowercased().contains(wanted) }
            if containing.count == 1 { return .one(containing[0]) }
            if containing.count > 1 {
                return .refused(.ambiguous(rivals: containing.map(\.name)))
            }
            return .refused(.noSuchTab(offered: tabs.map(\.name)))
        }
    }

    // MARK: - Acting

    /// Switch to a tab, and prove it.
    ///
    /// The caller must have brought the browser forward: pressing a tab in a
    /// background window is a real act with an invisible result, and the
    /// chord fallback would land wherever focus actually is.
    static func activate(
        _ target: Target, pid: pid_t, surface: PluginBrowserSurfaceSchema
    ) async -> Outcome {
        let tabs = read(pid: pid, surface: surface)
        let tab: Tab
        switch resolve(target, in: tabs) {
        case .one(let hit): tab = hit
        case .refused(let outcome): return outcome
        }
        if tab.isCurrent == true { return .switched(to: tab.name) }

        // AXPress on the tab element — the measured affordance in both
        // browsers, and the one that survives the strip re-flowing.
        var pressed = AXUIElementPerformAction(
            tab.element, kAXPressAction as CFString) == .success

        if !pressed, surface.ordinalChordFallback, tab.ordinal <= 9 {
            // The fallback a package has to ask for out loud, because it
            // addresses a POSITION. Only reached when the element's own
            // affordance was refused.
            pressed = KeyChordPress.press(
                key: ordinalKey(tab.ordinal), modifiers: [.command])
        }
        guard pressed else { return .didNotTake(tab.name) }

        try? await Task.sleep(for: .milliseconds(400))

        // THE PROOF. Re-read and ask whether the tab we pressed is now the
        // current one. A press that was accepted and ignored is otherwise
        // indistinguishable from one that worked.
        let after = read(pid: pid, surface: surface)
        // Nil covers two cases that report the same way and mean slightly
        // different things: the tab is gone, or the browser publishes no
        // readable current-tab signal right now (the `windowTitle` signal
        // against two identically-titled pages). Either way the press was
        // delivered and CANNOT BE CONFIRMED, and an unconfirmed act is not a
        // success however likely it is to have worked.
        guard after.first(where: { $0.name == tab.name })?.isCurrent == true else {
            return .didNotTake(tab.name)
        }
        return .switched(to: tab.name)
    }

    /// Close a tab, and prove the roster shrank.
    ///
    /// SWITCH FIRST, ALWAYS. Every close road except a per-tab button acts on
    /// whatever is current, so closing "the GitHub tab" without switching to
    /// it first closes whatever the user happened to be looking at. That is
    /// destructive and silent, and it is why this is one function rather than
    /// a chord the caller may send.
    static func close(
        _ target: Target, pid: pid_t, surface: PluginBrowserSurfaceSchema
    ) async -> Outcome {
        let tabs = read(pid: pid, surface: surface)
        let tab: Tab
        switch resolve(target, in: tabs) {
        case .one(let hit): tab = hit
        case .refused(let outcome): return outcome
        }
        let before = tabs.count

        switch surface.closeAffordance {
        case .childButton:
            // Chrome's shape: a Close button living inside the tab.
            let label = (surface.closeControlLabel ?? "Close").lowercased()
            let closer = AX.children(tab.element).first { child in
                [kAXTitleAttribute, kAXDescriptionAttribute].contains { attribute in
                    AX.string(child, attribute)?.lowercased() == label
                }
            }
            guard let closer,
                  AXUIElementPerformAction(closer, kAXPressAction as CFString) == .success
            else { return .didNotTake(tab.name) }

        case .elementAction:
            // Safari's shape: a named action on the tab itself.
            guard let action = surface.closeControlLabel,
                  AXUIElementPerformAction(tab.element, action as CFString) == .success
            else { return .didNotTake(tab.name) }

        case .chordOnly:
            guard case .switched = await activate(target, pid: pid, surface: surface)
            else { return .didNotTake(tab.name) }
            let chord = surface.closeTabChord ?? PluginChord(key: .w, modifiers: [.command])
            guard KeyChordPress.press(key: chord.key, modifiers: chord.modifiers)
            else { return .didNotTake(tab.name) }
        }

        try? await Task.sleep(for: .milliseconds(400))

        // THE PROOF IS THE COUNT, not the absence of the name. Two tabs can
        // share a name, and a browser closing the wrong one of them would
        // pass a name check while the roster is one shorter either way.
        // Counting says a tab closed; it does not say which, which is why
        // the switch above matters.
        let after = read(pid: pid, surface: surface)
        guard after.count < before else { return .didNotTake(tab.name) }
        return .closed(tab.name)
    }

    /// ⌘1…⌘9. Only reached behind `ordinalChordFallback`.
    static func ordinalKey(_ ordinal: Int) -> PluginKey {
        switch ordinal {
        case 1: return .one
        case 2: return .two
        case 3: return .three
        case 4: return .four
        case 5: return .five
        case 6: return .six
        case 7: return .seven
        case 8: return .eight
        default: return .nine
        }
    }
}
