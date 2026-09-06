//
//  PageChallenge.swift
//  MaryPlugin
//
//  WHAT: Recognising a "verify you are human" interstitial, from the title the
//        shell already read — and the words its visible control carries.
//  IN:   WebSurfaceAX.Reading.title (no new read, no script)
//  OUT:  BrowserEngine.satisfyChallenge
//  PIN:  PRESS THE CHECKBOX THAT IS ON SCREEN, ONCE. NOTHING MORE THAN THAT.
//        A site may put an anti-bot interstitial in front of a page a person
//        asked to reach, and the common one renders as a real checkbox labelled
//        "Verify you are human". Mary is driving the person's OWN browser on
//        their OWN machine, present and authorising the turn, so she can press
//        that control the same way she presses a cookie notice's Accept button
//        or a save dialog's button — it is a visible control the person could
//        click themselves, and the click is the real cursor moving through the
//        HID tap, which is a genuine human-visible interaction, not a forgery.
//        WHAT THIS IS NOT, and the line is bright. It does not forge a clearance
//        token, spoof a user agent or a fingerprint, inject a solved-challenge
//        token, route through a solving service, or otherwise defeat the check
//        at the protocol level. It answers the check by OPERATING ITS CONTROL,
//        once, and looks again. If the one press does not clear it, the honest
//        refusal stands — `BrowserRefusal.humanCheck` exists precisely so Mary
//        can say "this one needs you" rather than pretend, hammer, or evade. A
//        challenge exists to confirm a human is driving; a human IS driving.
//        TITLE-BORNE, BECAUSE THE TITLE IS ALREADY IN HAND. The reference port
//        (Bonnie) spawns a scripted title poll every half-second; Mary reads the
//        shell title through Accessibility on every shell read, so detection
//        costs nothing beyond a prefix check — and Mary scripts no browser
//        (`NoAppleEventsTests`).
//

import CoreGraphics
import Foundation
import MaryComputerUse

enum PageChallenge {

    /// Titles a bot-check interstitial shows while it decides whether a person
    /// is present. MEASURED against the common managed-challenge and Turnstile
    /// interstitials; matched on the FRONT of the folded title, because the site
    /// name is often appended after it.
    static let titles = [
        "just a moment",
        "attention required",
        "checking your browser",
        "checking if the site connection is secure",
        "please wait",
        "verifying you are human",
        "one moment please",
        "one more step",
    ]

    /// The words the visible control carries — a checkbox, or the button that
    /// stands in for one. Routed as a page phrase like any other name.
    static let controlPhrases = [
        "verify you are human",
        "i am human",
        "i'm not a robot",
        "im not a robot",
    ]

    /// The primary phrase a press is aimed at. The alternates above are for the
    /// widget variants; the driven corpus is what promotes one of them if a real
    /// page needs it.
    static let primaryControlPhrase = "verify you are human"

    /// Is the page the browser is showing a human-check interstitial, judged
    /// from its title alone?
    ///
    /// PIN: FRONT-OF-TITLE, FOLDED. "Just a moment... - example" and
    /// "Just a moment…" are the same interstitial; the ellipsis and the trailing
    /// site name are noise. A page whose title merely CONTAINS "please wait" in
    /// its body is not one — the interstitial OWNS the title, so the match is a
    /// prefix.
    static func isChallenge(title: String?) -> Bool {
        guard let folded = folded(title) else { return false }
        return titles.contains { folded.hasPrefix($0) }
    }

    /// Whether a phrase names the challenge's own control.
    ///
    /// PIN: BOTH SIDES FOLDED. "I'm not a robot" folds to "i m not a robot" —
    /// the apostrophe becomes a space — so a stored phrase carrying one would
    /// never match the folded input. The control phrases are folded here, once,
    /// rather than pre-folded in the list, so the list stays readable.
    static func namesControl(_ phrase: String) -> Bool {
        guard let candidate = folded(phrase) else { return false }
        return controlPhrases.contains { needle in
            guard let folded = folded(needle) else { return false }
            return candidate.contains(folded)
        }
    }

    // MARK: - Where to press

    /// The widest a checkbox is, in points. A real one is 20–32; anything
    /// wider is a button or a card.
    static let checkboxMaxSide: CGFloat = 40
    /// How far from square a checkbox may read. Edge detection rounds corners.
    static let checkboxSquareness: CGFloat = 8
    /// How far left of the label's text the box may sit and still be its box.
    static let checkboxGap: CGFloat = 32
    /// Where in the label to press when no separate box was read: just inside
    /// its left edge, the end nearest the box, inside the widget's own hit area.
    static let labelInset: CGFloat = 8

    /// WHERE THE PRESS GOES, AND WHAT IT IS AIMED AT.
    ///
    /// PIN: THE CHECKBOX, NOT THE MIDDLE OF THE SENTENCE. The reference port
    /// found the control through the accessibility tree; Mary reads the page
    /// from pixels, where "Verify you are human" arrives as a text row and the
    /// box beside it, when the edge detector caught it, as a small square row on
    /// the same line. Pressing the text's centre lands on words; the box is what
    /// toggles. So the aim is the box when one was read, and otherwise the
    /// label's own left edge — inside the widget's hit area, at the end nearest
    /// the box — rather than a guess into empty page to the left of it. The
    /// driven corpus is what moves that fallback if a real page needs it.
    static func aim(in rows: [PageRow]) -> (point: CGPoint, named: String)? {
        guard let label = rows.first(where: { namesControl($0.label) }) else { return nil }
        let text = label.frame
        let box = rows
            .filter { row in
                row.ordinal != label.ordinal
                    && row.frame.width <= checkboxMaxSide
                    && row.frame.height <= checkboxMaxSide
                    && abs(row.frame.width - row.frame.height) <= checkboxSquareness
                    && row.frame.maxX <= text.minX + checkboxGap
                    && row.frame.maxX >= text.minX - checkboxGap - checkboxMaxSide
                    && row.frame.minY < text.maxY && row.frame.maxY > text.minY
            }
            // The nearest one to the label's left edge is its box.
            .max { $0.frame.maxX < $1.frame.maxX }
        if let box {
            return (
                CGPoint(x: box.frame.midX.rounded(), y: box.frame.midY.rounded()),
                "the checkbox beside \"\(label.label)\"")
        }
        return (
            CGPoint(x: (text.minX + labelInset).rounded(), y: text.midY.rounded()),
            "\"\(label.label)\"")
    }

    /// Lower-cased, letters and digits and single spaces — the same folding the
    /// row facts compare with, so a title and a control read the same way.
    static func folded(_ value: String?) -> String? {
        guard let value else { return nil }
        let folded = String(value.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
            .split(separator: " ")
            .joined(separator: " ")
        return folded.isEmpty ? nil : folded
    }
}
