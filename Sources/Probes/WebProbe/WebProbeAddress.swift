//
//  WebProbeAddress.swift
//  WebProbe
//
//  CAN THE ADDRESS BAR BE SET, rather than typed into?
//
//  The predecessor navigated through the browser's scripting dictionary, and
//  recorded a measurement Mary has to answer some other way: `/usr/bin/open`
//  RE-USES the current tab, and navigating away from a page with unsaved
//  edits fires its `beforeunload` handler — whose dialog makes the web area
//  DISAPPEAR from the accessibility tree entirely. The probe that found it saw
//  a browser with a toolbar and no page, and every search for the editor
//  honestly returned nothing.
//
//  So Mary needs a genuinely NEW tab, and the obvious road is ⌘T then ⌘L then
//  type. Typing is the part worth avoiding: the omnibox autocompletes inline
//  as characters arrive, so a Return at the end can commit a completion
//  rather than what was typed — landing on a different site, plausibly, with
//  nothing failing.
//
//  This asks whether there is a third road: is the address field's VALUE
//  settable through Accessibility? If it is, a navigation is ⌘T, one atomic
//  set, and Return — no per-character race, no autocomplete to outrun, and
//  no Apple Event. That would be more precise than either road the
//  predecessor had.
//
//    mary-web-probe address [--app <name>]        report only
//    mary-web-probe address --set <url>           set it, and Return
//

import AppKit
import ApplicationServices
import Foundation
import MaryAmbient
import MaryPlugin

enum WebProbeAddress {

    /// How the two browsers name the field, measured 2026-08-28: Safari puts
    /// the URL in the VALUE and gives no useful title; Chrome describes it
    /// "Address and search bar". Both are `AXTextField` in the toolbar.
    static let addressHints = ["address", "search bar", "url", "enter website name"]

    static func run(_ application: NSRunningApplication, set url: String?) async {
        let pid = application.processIdentifier
        let name = application.localizedName ?? "\(pid)"
        let element = AXUIElementCreateApplication(pid)

        print("▸ \(name) (pid \(pid))")

        guard let window = AX.element(element, kAXFocusedWindowAttribute)
                ?? AX.element(element, kAXMainWindowAttribute) else {
            print("  No focused or main window.")
            return
        }
        guard let field = addressField(in: window) else {
            print("  No address field found in the toolbar.")
            return
        }

        let value = AX.string(field, kAXValueAttribute)
        let description = AX.string(field, kAXDescriptionAttribute)
        let title = AX.string(field, kAXTitleAttribute)

        var valueSettable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(
            field, kAXValueAttribute as CFString, &valueSettable)
        var focusSettable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(
            field, kAXFocusedAttribute as CFString, &focusSettable)

        print("""
          field       AXTextField
          title       \(title ?? "—")
          description \(description ?? "—")
          value       \(value ?? "—")
          AXValue     \(valueSettable.boolValue ? "SETTABLE" : "not settable")
          AXFocused   \(focusSettable.boolValue ? "settable" : "not settable")
        """)

        guard let url else {
            print("""

              Pass --set <url> to try a navigation: focus the field, set its
              value in one write, press Return, then watch it settle.
            """)
            return
        }

        guard valueSettable.boolValue else {
            print("""

              NOT SETTABLE — so navigation cannot be one atomic write, and the
              lane has to type into the omnibox and outrun its autocomplete.
              That is the finding; it changes the design, not the code here.
            """)
            return
        }

        print("\n  setting to \(url)…")
        AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        try? await Task.sleep(for: .milliseconds(200))
        let status = AXUIElementSetAttributeValue(
            field, kAXValueAttribute as CFString, url as CFTypeRef)
        print("  set         \(status.rawValue == 0 ? "0 (success)" : "\(status.rawValue)")")

        let readBack = AX.string(field, kAXValueAttribute)
        print("  reads back  \(readBack ?? "—")\(readBack == url ? "  ✓ exactly what was written" : "  ⚠︎ DIFFERS")")

        _ = KeyChordPress.press(key: .return, modifiers: [])
        print("  Return      posted")

        let verdict = await WebLoadSettle.await(pid: pid)
        print("  settle      \(verdict)")
        print("  now at      \(AX.string(field, kAXValueAttribute) ?? "—")")
    }

    /// The toolbar's address field. Scoped to the toolbar deliberately: a
    /// page is full of text fields, and one of them is a search box.
    static func addressField(in window: AXUIElement) -> AXUIElement? {
        var found: AXUIElement?
        AXTreeWalker.walk(from: window, budget: .init(maxDepth: 12, maxNodes: 400)) { element, _ in
            guard found == nil else { return }
            guard AX.string(element, kAXRoleAttribute) == kAXTextFieldRole as String
            else { return }
            let label = [
                AX.string(element, kAXTitleAttribute),
                AX.string(element, kAXDescriptionAttribute),
            ].compactMap { $0 }.joined(separator: " ").lowercased()
            let value = AX.string(element, kAXValueAttribute) ?? ""
            // Named like an address bar, OR already holding a URL — Safari
            // names it neither way and only its value gives it away.
            if addressHints.contains(where: label.contains)
                || value.hasPrefix("http") || value.contains("://") {
                found = element
            }
        }
        return found
    }
}
