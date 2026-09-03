//
//  AbilityRuntime+Locate.swift
//  MaryBrain
//
//  WHAT: Locating what a revision is about — never reading it.
//  IN:   EditIntent targets + the leading world's open body
//  OUT:  a minted LocatedPassage, or nil at the last rung
//  PIN:  A ladder: stop at the first rung that yields; only the last gives up.
//
import Foundation

extension AbilityRuntime {

    // MARK: - Locating what a revision is about

    /// Locate, not read — resolve the named part against the leading world's open body.
    /// PIN: One line of this file knows `EditIntent`; other fields stay unused.
    public func locatePassage(_ intent: EditIntent) async -> LocatedPassage? {
        await locatePassage(targets: intent.target, anaphoric: intent.isAnaphoric)
    }

    public func locatePassage(
        _ intent: EditIntent, attentionHint: AmbientAttention?
    ) async -> LocatedPassage? {
        await locatePassage(
            targets: intent.target, anaphoric: intent.isAnaphoric,
            attentionHint: attentionHint)
    }

    /// Locate ladder — stop at the first rung that yields; only the last gives up.
    func locatePassage(
        targets: [String], anaphoric: Bool = false,
        attentionHint: AmbientAttention? = nil, now: Date = Date()
    ) async -> LocatedPassage? {
        // Same focus decision the prompt, roster hoist, deposit subject, and pre-read use.
        let recentAnaphoricPassage = anaphoric ? passages.live(at: now).first : nil
        let owner = focusProvider?() ?? attentionHint?.pluginOwner
            ?? recentAnaphoricPassage?.place.memoryToken
        guard let owner,
              let verb = targetedEdits[owner],
              // Mirrors `readNamedPart`'s check that the declared binding is really in the catalog
              skillBindings.contains(where: { $0.name == verb.binding }),
              let backing = passageBackings[owner]
        else { return nil }

        // Dictionary lookups so far — worlds with no documents cost nothing and read no body.
        guard let snapshot = await backing.body() else { return nil }

        var wanted = targets
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // `routedSelectionHandoff`: turn-local snapshot plus the route's own gate.
        if anaphoric,
           let handoff = world.store.routedSelectionHandoff(attention: backing.place.attention) {
            let selected = handoff.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !selected.isEmpty { wanted.append(selected) }
        }

        // Recent passage joins as a target rather than short-circuiting the ladder.
        if anaphoric,
           let recent = recentAnaphoricPassage ?? passages.live(at: now)
            .first(where: { $0.place == backing.place }) {
            wanted.append(recent.text)
        }

        // Rungs 1–3. `PassageEditRunner.mint` is the ladder and mint the Skill bindings use.
        for (index, target) in wanted.enumerated() {
            guard case .found(let found) = await PassageEditRunner.mint(
                target: target, in: snapshot, backing: backing,
                registry: passages, ambient: world.store, now: now)
            else { continue }
            return LocatedPassage(
                passage: found.passage, label: found.label, verb: verb,
                widened: index > 0 || Self.chosenForThem(found))
        }

        // Rung 4, then 5.
        return fallbackPassage(in: snapshot, backing: backing, verb: verb, now: now)
    }

    /// True when we chose the span rather than their words matching whole.
    /// PIN: False only for a single candidate on a whole-target rung.
    static func chosenForThem(_ found: PassageEditRunner.Located) -> Bool {
        guard found.confidence == .exact, let rung = found.rung else { return true }
        switch rung {
        case .verbatim, .structural, .normalized: return false
        case .tokenOverlap, .widened:             return true
        }
    }

    /// Rung 4 — named target missed; fall back to where they are (selection, then attention).
    private func fallbackPassage(
        in snapshot: BodySnapshot,
        backing: PassageBacking,
        verb: (binding: String, parameter: String),
        now: Date
    ) -> LocatedPassage? {
        let units = backing.units(snapshot.text)

        // Source-owned handoff keeps the full AX text.
        // PIN: Not `requiringWritingTarget: true` — that flag killed this rung in production.
        let selected = (world.store.routedSelectionHandoff(
            attention: backing.place.attention)?.text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !selected.isEmpty,
           // First occurrence — same as `PassageAttention`'s `range(of:)` anchor.
           let span = PassageWidening.occurrences(of: selected, in: snapshot.text).first {
            let unit = units.first { $0.range == span }
            return mintFallback(
                span: span, kind: unit?.kind ?? .window, label: unit?.label ?? "",
                note: "what you had selected",
                in: snapshot, backing: backing, verb: verb, now: now)
        }

        guard let anchor = PassageEditRunner
                .attention(for: backing.place, ambient: world.store)?
                .anchor(in: snapshot.text),
              let unit = units
                .filter(\.kind.isBlock)
                // Empty span at a unit's upper bound is outside it.
                .filter({ $0.contains(anchor..<anchor) })
                .min(by: { $0.length < $1.length })
        else { return nil }   // RUNG 5. Nothing to gate on; the turn is unchanged.

        return mintFallback(
            span: unit.range, kind: unit.kind, label: unit.label,
            note: "the part you're working in",
            in: snapshot, backing: backing, verb: verb, now: now)
    }

    /// Mint via `PassageRecipes.mintRead` — the one place a read mints a handle.
    private func mintFallback(
        span: Range<Int>,
        kind: PassageUnitKind,
        label: String,
        note: String,
        in snapshot: BodySnapshot,
        backing: PassageBacking,
        verb: (binding: String, parameter: String),
        now: Date
    ) -> LocatedPassage? {
        guard let passage = PassageRecipes.mintRead(
            place: backing.place,
            documentKey: snapshot.documentKey,
            documentTitle: snapshot.documentTitle,
            body: snapshot.text,
            range: span,
            kind: kind,
            locatorNote: note,
            registry: passages,
            at: now)
        else { return nil }
        // Always widened — we chose this span because nothing they named was found.
        return LocatedPassage(passage: passage, label: label, verb: verb, widened: true)
    }
}
