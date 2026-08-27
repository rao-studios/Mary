//
//  AmbientAffordance.swift
//  MaryAmbient
//
//  SOMETHING THE SCREEN IS OFFERING RIGHT NOW.
//
//  A neutral value, deliberately free of Accessibility: MaryAmbient must
//  stay a pure package (it is depended on by the brain, the plugins, and the
//  app), so the AX walk lives in `MaryAdapter` and hands its findings
//  across as these. The same reason `Passage` carries text rather than an
//  `AXUIElement`, and the reason a Sketch layer arrives as `AmbientArtifact`.
//
//  IT IS NOT A PAGE ELEMENT. `PageElement` carries a live `AXUIElement`,
//  which is stale the moment the page reflows — which is why every act
//  re-reads before touching. What crosses into ambient memory is only what
//  stays true long enough to be MEANT: an id, a label, the word for its
//  role. Resolution answers "which one did they mean"; the hands re-find it
//  by IDENTITY and press whatever is there NOW.
//
//  `frame` DOES NOT CHANGE THAT — it is the one addition to the rule above,
//  and it earns its place by being a different kind of thing than the
//  coordinate this header used to warn against. A raw `CGRect` IS a claim
//  about now; `AXFrame` is capture-stamped evidence about a moment that has
//  already passed by the time anyone reads it. It answers "roughly where
//  was this, for aiming and reasoning" — never "click exactly here without
//  looking again". `id` stays the sole re-finding key; nothing resolves,
//  ranks, or re-locates by frame.
//
//  WHY IT HAS NO CAPABILITY FIELD: `AffordanceRule` derives capabilities from
//  the role word, so a publisher cannot claim a text field is pressable.
//

import Foundation

/// One actionable thing on screen, as ambient memory holds it.
public struct AmbientAffordance: Sendable, Equatable, Identifiable {

    /// Stable within one publish — the publisher's own handle, used to
    /// re-find the element before acting. Never spoken.
    public var id: String
    /// What the thing calls itself, in its own words: "Skip Ads",
    /// "Full screen (f)", "Sign in". This is the whole reason a goal can
    /// reach it — the embedding matches "skip the ad" against these words,
    /// not against a table Mary wrote.
    public var label: String
    /// The humanized role: "button", "link", "field", "video". Lowercased,
    /// and the word a person would actually say.
    public var roleWord: String
    /// Reading-order position among the publisher's affordances, 1-based —
    /// what "the third one" counts.
    public var ordinal: Int
    /// Whether it can be acted on at this instant. A disabled control is
    /// still perceived (so "why can't I press Continue" has an answer) but
    /// resolution will not offer it.
    public var isEnabled: Bool
    /// The control's own help text, when it has one. Frequently the only
    /// place a terse label explains itself.
    public var help: String?
    /// Where it was, at the moment it was published — evidence, not a
    /// target. See the header. Nil when the producer had no geometry to
    /// offer (a synthesized or scripted affordance).
    public var frame: AXFrame?

    public init(
        id: String,
        label: String,
        roleWord: String,
        ordinal: Int,
        isEnabled: Bool = true,
        help: String? = nil,
        frame: AXFrame? = nil
    ) {
        self.id = id
        self.label = label
        self.roleWord = roleWord
        self.ordinal = ordinal
        self.isEnabled = isEnabled
        self.help = help
        self.frame = frame
    }
}

extension AmbientElementScope {

    /// THE AFFORDANCE PARTITION, and the reason `.pressable` is safe to add.
    ///
    /// Affordances live in their own key beside the realm's other slates —
    /// the browser's tab roster, a canvas's layers, a document's passages —
    /// so a phrase resolving against tabs can never rank a button, and a
    /// press can never land on a paragraph however similar the words. That
    /// separation is what the earlier decision to omit a `.pressable`
    /// capability was protecting; with it, the capability costs nothing.
    public static func affordances(in realm: AmbientRealm) -> AmbientElementScope {
        AmbientElementScope(
            realm: realm, key: "\(realm.token)\(affordanceSuffix)")
    }

    /// How `AffordanceProbe` recognizes one of these partitions among all the
    /// slates the index holds. A suffix rather than a registry: the scope key
    /// is the only thing the store carries about a partition, and a second
    /// list of "which scopes are affordance scopes" would be the drift.
    public static let affordanceSuffix = ":affordances"
}
