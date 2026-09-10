//
//  AmbientElementRules.swift
//  MaryAmbient
//
//  WHAT: Shipped rulesets — how each world's elements serialize into embeddable records.
//  OUT:  AmbientElementIndexStore.noteElements
//  PIN:  Every rule embeds both kind and name. No artifact ruleset — design canvas arrives as a package.
//

import Foundation

// NO ARTIFACT RULESET.

public enum PassageRule: AmbientElementRuleset {

    public static func records(
        for elements: [Passage], scope: AmbientElementScope
    ) -> [AmbientElementRecord] {
        elements.map { passage in
            var texts = [passage.unitKind.rawValue]
            if !passage.documentTitle.isEmpty {
                texts.append(passage.documentTitle.lowercased())
            }
            let excerpt = String(passage.text.prefix(200))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !excerpt.isEmpty { texts.append(excerpt.lowercased()) }
            return AmbientElementRecord(
                scope: scope,
                elementID: passage.handle,
                kindWord: passage.unitKind.rawValue,
                name: passage.documentTitle.isEmpty ? nil : passage.documentTitle,
                embedTexts: texts,
                capabilities: [.prose],
                displaySummary: "\(passage.handle) \(passage.locatorNote)")
        }
    }
}

/// Held ambient facts. Evidence, not mutation targets — no capabilities, so
/// a `requires`-carrying resolution never lands on one; they participate in
/// "what does this phrase refer to" only.
public enum AmbientFactRule: AmbientElementRuleset {

    public static func records(
        for elements: [AmbientFact], scope: AmbientElementScope
    ) -> [AmbientElementRecord] {
        elements.map { fact in
            var texts = [fact.slotPhrase]
            if let subject = fact.subject?.lowercased(), !subject.isEmpty {
                texts.append(subject)
            }
            let prefix = String(fact.content.prefix(200))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty { texts.append(prefix.lowercased()) }
            return AmbientElementRecord(
                scope: scope,
                elementID: fact.id,
                kindWord: fact.slotPhrase,
                name: fact.subject,
                embedTexts: texts,
                capabilities: [],
                displaySummary: fact.slotPhrase)
        }
    }
}

/// Things on screen that can be acted on right now — a page's buttons and links, an
/// application window's controls. NO GOAL TABLE, AND THIS IS THE WHOLE POINT.
public enum AffordanceRule: AmbientElementRuleset {

    /// The role words this rule understands, and what each one may serve. Closed and small:
    /// these are Mary's own humanized words for public Accessibility roles (`PageElementKind`),
    /// not anything a page or a package supplies.
    static func capabilities(
        forRoleWord role: String
    ) -> AmbientElementCapabilities {
        switch role {
        case "button", "link", "video", "option", "row", "image":
            return [.pressable]
        // A field is BOTH: clicking it is how you focus it, typing is what
        // you came for.
        case "field":
            return [.pressable, .fillable]
        // A heading is a landmark. It can be scrolled to, never pressed —
        // and there is no capability for "can be revealed" because reveal
        // is safe on anything the reader publishes.
        default:
            return []
        }
    }

    public static func records(
        for elements: [AmbientAffordance], scope: AmbientElementScope
    ) -> [AmbientElementRecord] {
        elements.compactMap { affordance in
            let label = affordance.label
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // An unlabelled control cannot be MEANT — there are no words to reach it with, and
            // offering it would let a goal land on a nameless icon. The reader still counts it;
            // ambient memory does not hold it.
            guard !label.isEmpty else { return nil }
            let role = affordance.roleWord.lowercased()
            var texts = [label.lowercased(), role]
            texts.append("\(role) labelled \(label.lowercased())")
            if let help = affordance.help?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !help.isEmpty {
                texts.append(String(help.prefix(160)).lowercased())
            }
            // A DISABLED CONTROL IS PERCEIVED BUT NOT OFFERED. It keeps its record so "why can't I
            // press Continue" has an answer — and loses every capability, so `requires: .pressable`
            // filters it out before anything can try.
            let capabilities = affordance.isEnabled
                ? capabilities(forRoleWord: role)
                : []
            return AmbientElementRecord(
                scope: scope,
                elementID: affordance.id,
                kindWord: role,
                name: label,
                embedTexts: texts,
                capabilities: capabilities,
                displaySummary: label)
        }
    }
}
