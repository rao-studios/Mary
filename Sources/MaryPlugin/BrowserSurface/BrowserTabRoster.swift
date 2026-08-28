//
//  BrowserTabRoster.swift
//  MaryPlugin
//
//  THE TABS, READ FROM THE BROWSER'S OWN TREE — and pressed by identity.
//
//  The predecessor asked each browser's scripting dictionary for a `tabs`
//  collection and set `current tab` to switch. Mary sends no Apple Events, so
//  this reads the strip the browser draws and presses the tab a person would
//  click. That turned out to be MORE precise rather than less, and the reason
//  is worth stating plainly: an Apple Event names a tab by INDEX, so "the
//  third tab" is resolved by counting, and the count changes underneath a
//  turn whenever a tab opens or closes. A pressed element is the tab itself.
//
//  WHAT IS DECLARED AND WHAT IS COMPILED. The strip's role, where a tab keeps
//  its name, how the browser says which one is current, and how one is closed
//  all come from `PluginBrowserSurfaceSchema` — six axes on which the two
//  measured browsers disagree (see that file's header). What is compiled here
//  is everything that is true of all of them: how to find a declared
//  container, how to turn it into an ordered roster, how to resolve a spoken
//  target against that roster, and how to prove a press landed.
//
//  ORDINALS ARE OFFERED AND NEVER TRUSTED AS IDENTITY. "The third tab" is a
//  real thing to say, so the roster is numbered. But an ordinal is resolved
//  to an ELEMENT at read time and the element is what gets pressed — the
//  number is never carried into the act. A roster read seconds ago describes
//  a strip that may have re-flowed; the element does not renumber.
//
//  LIVE, 2026-08-28 (`mary-web-probe roster`), one compiled roster and two
//  declarations that share no field value:
//
//    Safari  strip AXOpaqueProviderGroup/AXOpaqueProviderList, names in
//            title, current by window title — 4 tabs in 149 ms; switching by
//            the fragment "Hacker" landed on "Hacker News" and confirmed.
//    Chrome  strip AXTabGroup, names in description, current by AXSelected —
//            4 tabs in 6 ms; switching by ordinal 1 landed and confirmed.
//
//  Chrome appends live diagnostics to a tab's description ("… - Memory usage
//  - 124 MB"), which is harmless here only because names are matched by
//  fragment and never by equality alone.
//

import AppKit
import ApplicationServices
import Foundation
import MaryFoundation

public enum BrowserTabRoster {

    /// One tab, as read.
    public struct Tab: Equatable {
        /// 1-based position in the strip, left to right. What a person means
        /// by "the third tab", and nothing more than that.
        public var ordinal: Int
        public var name: String
        /// Whether this is the tab on screen. Nil when the browser publishes
        /// no signal Mary can read AND the window title matched more than one
        /// tab — absent rather than false, because "not current" and "cannot
        /// tell" send a caller to different sentences.
        public var isCurrent: Bool?
        public var element: AXUIElement

        public init(ordinal: Int, name: String, isCurrent: Bool?, element: AXUIElement) {
            self.ordinal = ordinal
            self.name = name
            self.isCurrent = isCurrent
            self.element = element
        }
    }

    /// Chrome nests its strip seven or eight levels down, Safari hangs it off
    /// the window. Deep enough for the former, and still shallow enough that
    /// the walk cannot reach page content — the strip is chrome, and a search
    /// that found a page's own tab widget would report the page's tabs as the
    /// browser's.
    static let stripBudget = AXTreeWalker.Budget(maxDepth: 12, maxNodes: 600)

    // MARK: - Reading

    /// Read the strip in a browser's focused-or-main window.
    public static func read(
        pid: pid_t, surface: PluginBrowserSurfaceSchema
    ) -> [Tab] {
        let application = WebSurface.application(pid: pid)
        guard let window = WebSurface.focusedWindow(in: application) else { return [] }
        let windowTitle = AX.string(window, kAXTitleAttribute)

        guard let strip = locateStrip(in: window, surface: surface) else { return [] }
        let children = AX.children(strip)
            .filter { AX.string($0, kAXRoleAttribute) == surface.tabRole }

        let names = children.map {
            AX.string($0, surface.tabNameAttribute.attributeName)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let selectedFlags = children.map {
            AX.number($0, kAXSelectedAttribute)?.boolValue
        }
        return assemble(
            names: names, selectedFlags: selectedFlags,
            windowTitle: windowTitle, surface: surface,
            element: { children[$0] })
    }

    /// Find the declared container.
    ///
    /// THE SUBROLE MATTERS WHERE IT IS DECLARED: Safari's strip is an
    /// `AXOpaqueProviderGroup` and so are other things in the same window;
    /// only the `AXOpaqueProviderList` subrole picks the strip out. Where a
    /// package declares no subrole the role alone decides, which is what
    /// Chrome's uniquely-named `AXTabGroup` allows.
    ///
    /// A CONTAINER WITH NO TABS IN IT IS NOT THE STRIP. A window can hold
    /// several elements of the declared role, and the first one found is not
    /// necessarily the one holding tabs — so a candidate must actually
    /// contain a child of `tabRole` to win.
    static func locateStrip(
        in window: AXUIElement, surface: PluginBrowserSurfaceSchema
    ) -> AXUIElement? {
        var found: AXUIElement?
        AXTreeWalker.walk(from: window, budget: stripBudget) { element, _ in
            guard found == nil else { return }
            // The strip is never inside the page. Stopping the search from
            // descending would need a stop signal the walker does not have,
            // so a web area is skipped by test instead.
            guard AX.string(element, kAXRoleAttribute) == surface.tabStripRole else { return }
            if let wanted = surface.tabStripSubrole,
               AX.string(element, kAXSubroleAttribute) != wanted { return }
            guard AX.children(element).contains(where: {
                AX.string($0, kAXRoleAttribute) == surface.tabRole
            }) else { return }
            found = element
        }
        return found
    }

    /// THE WHOLE ORDERING AND CURRENT-TAB DECISION, over injected reads.
    ///
    /// Pure because the interesting cases are configurations a live browser
    /// produces only by chance: two tabs whose pages share a title, a strip
    /// whose names are all empty, a browser publishing no selection flag at
    /// all. Each is one fixture here and an afternoon of tab-juggling there.
    static func assemble(
        names: [String],
        selectedFlags: [Bool?],
        windowTitle: String?,
        surface: PluginBrowserSurfaceSchema,
        element: (Int) -> AXUIElement
    ) -> [Tab] {
        // WHICH TAB IS CURRENT, by the declared signal only. Falling back
        // from one signal to the other would paper over a package declaring
        // the wrong one, and a browser silently mis-declared is a browser
        // that reports the wrong current tab forever.
        let currentIndex: Int? = {
            switch surface.selectionSignal {
            case .selectedAttribute:
                return selectedFlags.firstIndex { $0 == true }
            case .windowTitle:
                guard let windowTitle, !windowTitle.isEmpty else { return nil }
                // The window title is the current page's title, sometimes
                // with the browser's name appended, so containment rather
                // than equality — exact matching misses every browser that
                // decorates.
                let matches = names.indices.filter { index in
                    let name = names[index]
                    return !name.isEmpty && windowTitle.contains(name)
                }
                if matches.count == 1 { return matches[0] }
                guard !matches.isEmpty else { return nil }

                // THE LONGEST MATCH IS THE MOST SPECIFIC ONE, and this rule
                // exists because the first live run needed it. Safari showing
                // "Accessibility - Wikipedia" alongside a tab named plainly
                // "Wikipedia" puts BOTH names inside the window title — so a
                // plain uniqueness test found two matches and reported that
                // it could not tell, for a browser with an obvious answer. A
                // short name being a substring of a longer one is not two
                // rivals; it is a general name and a specific one, and the
                // title is better explained by the specific.
                let longest = matches.map { names[$0].count }.max() ?? 0
                let best = matches.filter { names[$0].count == longest }
                // GENUINE AMBIGUITY SURVIVES: two tabs whose names are the
                // same length and both inside the title really are
                // indistinguishable here, and that is the weakness this
                // signal is documented to have.
                return best.count == 1 ? best[0] : nil
            }
        }()

        return names.indices.map { index in
            Tab(
                ordinal: index + 1,
                name: names[index],
                // Absent, not false, when nothing could decide: a roster
                // reporting every tab `false` claims to know that none is
                // current, which is never true of a browser with a window.
                isCurrent: currentIndex.map { $0 == index },
                element: element(index))
        }
    }
}
