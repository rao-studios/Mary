//
//  PageControlsReader.swift
//  MaryPlugin
//
//  WHAT THE PAGE OFFERS — the same enumeration `PageElementReader` performs
//  on a native window, rooted at the web area instead.
//
//  IT LIVES HERE AND NOT THERE, on that file's own instruction. Its header
//  says the web-page entry points "belong to the browser lane, with the web
//  sub-engine that finds the area in the first place" — and the reason is a
//  hazard no native window has: a browser's window holds the address bar,
//  which is a perfectly settable `AXTextField`. A window-rooted read hands it
//  back as the page's first field, and a fill lands in the URL.
//
//  EVERYTHING BELOW THE ROOT IS SHARED, deliberately. The collected roles,
//  the label ladder, the size and viewport filters, reading order and
//  deduplication are statements about public Accessibility rather than about
//  browsers, so this calls the same machinery. What is browser-shaped is
//  exactly one line: where the walk starts.
//
//  READING ORDER IS THE ORDINAL, and that is what makes "the third video"
//  answerable. It comes from `publish`, which sorts into vertical bands and
//  then left to right — the order a person's eye takes, not the order the
//  DOM happens to be in.
//

import ApplicationServices
import Foundation

public enum PageControlsReader {

    /// Which web area to read when a page has several. A code editor's is
    /// usually the first breadth-first; a document editor nested in iframes
    /// wants the largest.
    public typealias Strategy = WebSurface.WebAreaStrategy

    /// Enumerate the page's interactive elements, in reading order.
    ///
    /// AN EMPTY ARRAY IS NOT AN ABSENT PAGE. A page can genuinely offer
    /// nothing pressable, and a page that was never exposed to Accessibility
    /// reads identically here — so the CALLER runs `BrowserAXReadiness` first
    /// and tells the two apart. Conflating them is the lie this lane refuses:
    /// "nothing to click on that page" and "I can't see that page" send a
    /// person to completely different places.
    public static func read(
        inApp application: AXUIElement,
        strategy: Strategy = .largest,
        limit: Int = PageElementReader.publishedLimit
    ) -> [PageElement] {
        guard let area = WebSurface.webArea(in: application, strategy: strategy)
        else { return [] }
        return read(inWebArea: area, limit: limit)
    }

    /// Window-rooted sibling, for a caller holding a proven window that must
    /// not re-read the application's mutable focused-window attribute midway
    /// through an interaction.
    public static func read(
        inWindow window: AXUIElement,
        strategy: Strategy = .largest,
        limit: Int = PageElementReader.publishedLimit
    ) -> [PageElement] {
        guard let area = WebSurface.webArea(inWindow: window, strategy: strategy)
        else { return [] }
        return read(inWebArea: area, limit: limit)
    }

    static func read(
        inWebArea area: AXUIElement,
        limit: Int = PageElementReader.publishedLimit
    ) -> [PageElement] {
        // THE VIEWPORT IS THE PAGE, not the window. Off-screen elements in a
        // long document are filtered against these bounds, and using the
        // window's would admit everything the toolbar overlaps.
        let viewport = AX.frame(of: area)

        var candidates: [PageElementReader.Candidate] = []
        AXTreeWalker.walk(
            from: area,
            budget: .init(
                maxDepth: PageElementReader.maxSearchDepth,
                maxNodes: PageElementReader.maxSearchNodes)
        ) { element, _ in
            guard candidates.count < PageElementReader.maximumCandidates else { return }
            guard let candidate = PageElementReader.candidate(from: element, viewport: viewport)
            else { return }
            candidates.append(candidate)
        }
        return PageElementReader.publish(
            PageElementReader.deduplicated(candidates), limit: limit)
    }

    /// Cheap proof that an act did something. The front window's title, which
    /// a browser rewrites on navigation — so a press that went somewhere
    /// changes it and a press that was swallowed does not.
    ///
    /// NOT SUFFICIENT ON ITS OWN, and callers treat it that way: plenty of
    /// real page actions change nothing in the title. An unchanged signature
    /// means "nothing observable happened", which is honest, rather than
    /// "the press failed", which would be a guess.
    public static func pageSignature(pid: pid_t) -> String? {
        WebSurface.windowTitle(pid: pid)
    }
}
