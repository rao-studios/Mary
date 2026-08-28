//
//  WebSurface+Navigation.swift
//  MaryPlugin
//
//  GOING SOMEWHERE — and the measurement that chose how.
//
//  THREE ROADS WERE AVAILABLE, and the third turned out to be the best of
//  them by a distance. Recorded here because the two rejected ones are the
//  obvious ones, and a later reader will otherwise wonder why neither was
//  taken.
//
//   1. `/usr/bin/open -b <bundle> <url>`. Atomic, needs no frontmost window,
//      sends no Apple Event from Mary. REJECTED on a measurement the
//      predecessor recorded and Mary has no reason to doubt: `open` RE-USES
//      the current tab, and navigating away from a page holding unsaved edits
//      fires its `beforeunload` handler. The resulting "are you sure you want
//      to leave" alert makes the web area DISAPPEAR from the accessibility
//      tree entirely — so the failure is not "navigation refused", it is a
//      browser that appears to have no page at all, and every subsequent
//      search honestly returns nothing.
//
//   2. ⌘T, ⌘L, then TYPE the address. A genuinely new tab, so `beforeunload`
//      never fires. REJECTED on the typing: the omnibox autocompletes inline
//      as characters arrive, so the Return at the end can commit a completion
//      instead of what was typed. That lands on a plausible different site
//      with nothing failing anywhere — the worst shape a bug can have.
//
//   3. ⌘T for the new tab, then SET the address field's value through
//      Accessibility, then Return. MEASURED 2026-08-28 on macOS 26, and it
//      works in both browsers:
//
//        Safari  AXValue settable · read back exactly · settled 0.75 s
//        Chrome  AXValue settable · read back exactly · settled 1.25 s
//
//      One atomic write, no per-character race, nothing to outrun. And it
//      buys a property neither other road has: the address can be READ BACK
//      AND COMPARED BEFORE Return is pressed, so Mary can decline to commit a
//      navigation that did not land exactly as written. A typed URL can only
//      be checked afterwards, by which time the page is already loading.
//
//  ONE SMALL ASYMMETRY, worth knowing before it looks like a bug: after
//  navigating, Chrome's address field reads back WITHOUT the scheme
//  ("example.net"), Safari with it. That is display normalization by the
//  browser and it happens after the commit; the read-back that matters — the
//  one before Return — is exact in both.
//

import AppKit
import ApplicationServices
import Foundation
import MaryFoundation

public extension WebSurface {

    /// How the two browsers name the field, measured: Safari describes it
    /// "smart search field", Chrome "Address and search bar". Neither gives
    /// it a title. The value fallback catches a browser that names it
    /// something else entirely — a field in the toolbar already holding a URL
    /// is the address bar whatever it calls itself.
    static let addressFieldHints = [
        "address", "search field", "search bar", "url", "enter website name",
    ]

    /// The toolbar's address field.
    ///
    /// SCOPED TO THE WINDOW CHROME AT A SHALLOW BUDGET, and the scope is
    /// load-bearing in both directions: a page is full of text fields and one
    /// of them is its own search box, while the address bar is always within
    /// a few levels of the window. A generous budget here would find a page's
    /// search box on a slow day and navigate by typing into it.
    static func addressField(in window: AXUIElement) -> AXUIElement? {
        var found: AXUIElement?
        AXTreeWalker.walk(from: window, budget: chromeBudget) { element, _ in
            guard found == nil else { return }
            guard AX.string(element, kAXRoleAttribute) == kAXTextFieldRole as String
            else { return }
            let label = [
                AX.string(element, kAXTitleAttribute),
                AX.string(element, kAXDescriptionAttribute),
            ].compactMap { $0 }.joined(separator: " ").lowercased()
            let value = AX.string(element, kAXValueAttribute) ?? ""
            if addressFieldHints.contains(where: label.contains)
                || value.hasPrefix("http") || value.contains("://") {
                found = element
            }
        }
        return found
    }

    /// What the front tab is showing, as the browser's own chrome reports it.
    ///
    /// READ FROM THE TOOLBAR, NOT THE PAGE, because `AXURL` on the web area
    /// is not readable in either browser (measured — see `WebLoadSettle`).
    /// Reading chrome also answers BEFORE the page does, which is what lets a
    /// caller confirm where it is going while it is still going there.
    static func currentAddress(pid: pid_t) -> String? {
        guard let window = focusedWindow(in: application(pid: pid)),
              let field = addressField(in: window)
        else { return nil }
        return AX.string(field, kAXValueAttribute).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Navigate, in a new tab by default.
    ///
    /// THE CALLER MUST HAVE BROUGHT THE BROWSER FORWARD AND VERIFIED IT.
    /// ⌘T and Return land wherever focus is, and this deliberately does not
    /// take that authority for itself — `VerifiedActivation` is the one road,
    /// and a navigation that silently raised a window would be a second.
    ///
    /// `settle` is part of the contract rather than the caller's follow-up:
    /// a navigation that returns before the page exists hands back a browser
    /// its caller will immediately misread as empty.
    @discardableResult
    static func openLocation(
        _ url: String,
        pid: pid_t,
        inNewTab: Bool = true,
        settleBudget: TimeInterval = WebLoadSettle.defaultBudget
    ) async -> Failure? {
        let application = application(pid: pid)

        if inNewTab {
            guard KeyChordPress.press(key: .t, modifiers: [.command]) else {
                return .couldNotOpenTab
            }
            // A new tab's chrome is up almost immediately, but its address
            // field is a NEW element — resolving one before the tab exists
            // finds the outgoing tab's field and navigates the wrong tab.
            try? await Task.sleep(for: .milliseconds(400))
        }
        guard !Task.isCancelled else { return .cancelled }

        guard let window = focusedWindow(in: application),
              let field = addressField(in: window)
        else { return .couldNotReachAddressBar }

        // Focus first: an unfocused omnibox accepts the value and then
        // discards it on the browser's next redraw in some states, and
        // focusing is free.
        AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        try? await Task.sleep(for: .milliseconds(150))

        let status = AXUIElementSetAttributeValue(
            field, kAXValueAttribute as CFString, url as CFTypeRef)
        guard status == .success else { return .couldNotReachAddressBar }

        // THE CHECK THE OTHER TWO ROADS CANNOT MAKE. Confirm the field holds
        // exactly what was written BEFORE committing it. A mangled or
        // partially-applied address is a navigation to somewhere else, and
        // this is the last moment at which declining costs nothing.
        guard AX.string(field, kAXValueAttribute) == url else {
            return .couldNotReachAddressBar
        }
        guard !Task.isCancelled else { return .cancelled }

        guard KeyChordPress.press(key: .return, modifiers: []) else {
            return .couldNotReachAddressBar
        }

        switch await WebLoadSettle.await(pid: pid, budget: settleBudget) {
        case .settled, .presentButChurning:
            return nil
        case .neverAppeared:
            return .neverLoaded
        }
    }
}
