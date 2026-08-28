//
//  MaryBrain+Vocabulary.swift
//  MaryBrain
//
//  The brain's deterministic sentence builders, moved out of
//  MaryBrain.swift: `routineLabel`, `stalledLine`, `couldNotActLine`,
//  `providerUnavailableLine`, `couldNotReplaceSelectionLine`, `filed`,
//  `spokenDuration`, `normalizedForEcho`, `addsNothing`, `doneMarker`,
//  `confirmQuestion`. Every sentence here is spoken or filed verbatim, and
//  every post-mortem came with its function.
//
//  Moved verbatim; no behavior change, no wording change. All members are
//  statics with no stored state; no access promotions were needed.
//

import MaryVoice
import Foundation

extension MaryBrain {

    /// Spoken label for the busy note and the stop ack — the user's own
    /// words, clipped ("typing the opening paragraph for section…").
    static func routineLabel(from userText: String) -> String {
        let words = userText.split(whereSeparator: \.isWhitespace).prefix(8)
        let clipped = words.joined(separator: " ")
        return clipped.isEmpty ? "that request" : clipped
    }

    /// THE HONEST STALL SENTENCE — one wording, four callers.
    ///
    /// The watchdog speaks it, the attached-lane bound speaks it, the action
    /// retry's bound speaks it, and the bare-stop path is deliberately NOT one
    /// of them (a stop has its own acknowledgement). It says three things in
    /// order: it did not finish, we stopped waiting, and asking again is the
    /// way forward. Duplicating it is how one copy ends up promising a retry
    /// that another copy does not offer.
    static func stalledLine(label: String) -> String {
        "That one stalled — \(label) never came back, so I stopped waiting. Ask me again and I'll retry."
    }

    /// THE OTHER HONEST FAILURE — nothing ran at all, and it is not a stall.
    ///
    /// Reached when the executor emitted no Skill call twice: once normally and
    /// once after `actionRetryNudge` re-rolled. It means the model declined,
    /// not that a command failed — a failing command produces an outcome and
    /// takes a different road entirely.
    ///
    /// CENTRALISED FOR `stalledLine`'S OWN REASON. This sentence was two
    /// verbatim copies, and that file comment says why that is a bug: "one
    /// copy ends up promising a retry that another copy does not offer".
    ///
    /// It names the request now. "I couldn't act on that" told the user
    /// nothing they could use, while suggesting an app name blamed requests
    /// that had already supplied one (including the flagship Sketch command).
    /// Say what is grounded — nothing ran — and CLOSE the request. The old
    /// tail ("ask me again and I'll retry") sat in history as an open
    /// promise, and the model kept it at the worst moment: a later "what do
    /// you see" turn read the canvas, spotted the stale request above the
    /// fold, and executed the mutation nobody had re-asked for. Dropped
    /// means dropped; only a fresh request re-arms it.
    /// SHE WROTE THE PROSE SHE OFFERED. Says WHERE, because the whole point
    /// of carrying the offer's place is that it may not be the window in
    /// front — and a write the user cannot find reads as a write that did not
    /// happen.
    ///
    /// No recipe name: this is heard aloud, the same rule the refusals here
    /// already keep.
    static func wroteOfferedProseLine(place: String?) -> String {
        guard let place, !place.isEmpty else {
            return "Done — I've put that in at your cursor."
        }
        return "Done — I've put that into \(place) at your cursor."
    }

    /// AND THE HONEST FAILURE. The typer's own summary carries the reason
    /// (nothing in front to type into, a permission missing), so it is passed
    /// through rather than replaced with a generic apology — the same reason
    /// `couldNotActLine` below states the condition and stops.
    static func couldNotWriteOfferedProseLine(detail: String) -> String {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "I couldn't put that on the page, so nothing has changed."
        }
        return "I couldn't put that on the page — \(trimmed)"
    }

    static func couldNotActLine(label: String) -> String {
        "I couldn't work out how to do that — \(label). Nothing ran, and I've set that request aside; say it again if you still want it."
    }

    /// A named Dynamic application remains recognizable when its machine
    /// permission is missing, even though blocked Skills are correctly absent
    /// from the model schema. This preflight turns that known readiness fact
    /// into an actionable, grounded reply instead of asking the user to name
    /// the app they already named.
    static func providerUnavailableLine(
        applicationID: String,
        snapshot: AbilityRuntimeSnapshot
    ) -> String? {
        guard let profile = snapshot.plugins.applicationProfiles.first(where: {
            $0.id == applicationID
        }) else { return nil }
        // Resolve only manifests belonging to this exact application.
        let manifests = snapshot.plugins.adapterManifests.filter {
            $0.resolvedProvider.applicationID == applicationID
        }
        guard !manifests.isEmpty else { return nil }
        guard manifests.allSatisfy({ !$0.isAvailable }) else { return nil }
        let reason = manifests.compactMap(\.unavailableReason).first
            ?? "its local operator is unavailable"
        if reason.lowercased().contains(PermissionKind.accessibility.rawValue) {
            return "\(profile.title)'s Ability is active, but Mary needs macOS Accessibility access before she can operate it. Allow Mary in System Settings → Privacy & Security → Accessibility."
        }
        return "\(profile.title)'s Ability is active, but its Dynamic Plugin is unavailable: \(reason)"
    }

    static func couldNotReplaceSelectionLine() -> String {
        "I couldn't apply that revision to the selection in its source app."
    }

    /// FILE A DETERMINISTIC SENTENCE ONTO THE TRANSCRIPT ACCUMULATION, whatever
    /// the EAR was told.
    ///
    /// Every sentence in the post-lane ladder is composed for the ear: a
    /// leading space when prose precedes it, none when it leads. After a
    /// takeover those two audiences disagree — the ear heard nothing, while the
    /// transcript and history still carry the retracted acknowledgement — and
    /// the same string is then correct spacing for one and wrong for the other.
    /// Without this the bubble reads "I'm on it…I tightened the Background
    /// section", two sentences welded together at the seam the retraction
    /// opened. One separator rule, applied where the text is FILED rather than
    /// where it is spoken.
    static func filed(_ text: String, _ sentence: String) -> String {
        let lead = sentence.hasPrefix(" ") ? String(sentence.dropFirst()) : sentence
        guard !lead.isEmpty else { return text }
        return text.isEmpty ? lead : text + " " + lead
    }

    /// The routine's own duration, said the way a duration is said. Feeds
    /// `ReadDelivery.detail` — no new ledger row, because the question the
    /// ledger answers ("where did that read go?") is unchanged and this is one
    /// more fact about the same delivery.
    static func spokenDuration(since spawn: DispatchTime) -> String {
        let elapsed = DispatchTime.now().uptimeNanoseconds &- spawn.uptimeNanoseconds
        return String(format: "%.1fs", Double(elapsed) / 1_000_000_000)
    }

    /// WHETHER THIS TURN IS ONE WHOLE-APPLICATION WINDOW VERB AND NOTHING
    /// ELSE — the gate on the deterministic window path in `runTurnBody`.
    ///
    /// Two questions, both of which must answer yes.
    ///
    /// FIRST, does the window classifier name one of the two verbs whose only
    /// parameter is an application? The classifier is consulted rather than
    /// re-implemented — it is the same vocabulary routing already uses, and a
    /// second copy of "what counts as listing windows" is how the two come to
    /// disagree. It is asked WITHOUT a document place: that argument can only
    /// widen what it matches, and widening is the direction that costs a user
    /// their command rather than costing them a millisecond.
    ///
    /// SECOND, is the utterance a single request? This path answers the whole
    /// turn and returns, so a compound request would have its second half
    /// silently dropped — "bring all the Pages windows forward and read me the
    /// first paragraph" must reach a lane that can do both. Conjunctions and
    /// clause punctuation are what a person joins two requests with, and a
    /// long sentence is one even when it joins them some other way.
    ///
    /// Nil means "not this path", which costs nothing: the ordinary turn runs.
    static func deterministicWindowVerb(_ utterance: String) -> String? {
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let words = trimmed.split { $0.isWhitespace }.map(String.init)
        guard words.count <= 12 else { return nil }
        let lowered = " " + words.joined(separator: " ").lowercased() + " "
        let joiners = [" and ", " then ", " also ", " after that ", " plus "]
        guard !joiners.contains(where: { lowered.contains($0) }) else { return nil }
        guard !trimmed.contains(";"), !trimmed.contains(","),
              !trimmed.contains("?") else { return nil }

        let intent = WindowManagementTurnClassifier.classify(utterance: trimmed)
        // A turn that explicitly asked for a script is asking for the model,
        // not for a shortcut past it.
        guard !intent.explicitlyRequestsScript else { return nil }

        switch intent.invocationName {
        case "bring_all_windows_forward":
            return intent.invocationName

        case "list_app_windows":
            // A SENTENCE THAT ALSO ASKS TO BRING SOMETHING FORWARD IS NOT A
            // PURE LIST, whatever the classifier concluded.
            //
            // THE FAILURE THIS PREVENTS (found while writing this path):
            // "bring the Shopping List window forward" classifies as
            // `list_app_windows`, because the classifier looks for the token
            // "list" anywhere in the utterance and the WINDOW'S TITLE contains
            // it. That misreading is survivable today — the classifier is
            // advisory, so the model still calls `bring_window_forward` and
            // the user gets their window. It would not be survivable here:
            // this path EXECUTES the verdict and returns, so the user would
            // ask for a window and be handed a list instead, with no round
            // left in which anything could notice.
            //
            // The check is a CONTRADICTION test, not a second copy of the
            // classifier's vocabulary: it does not decide what the turn means,
            // it only declines to act deterministically on a verdict the
            // sentence argues with. Any sentence carrying both readings falls
            // through to the ordinary turn, where the model settles it.
            let raiseWords = ["forward", "front", "raise", "unhide", "restore"]
            guard !raiseWords.contains(where: { lowered.contains(" \($0) ") }) else {
                return nil
            }
            return intent.invocationName

        default:
            return nil
        }
    }

    /// The same clock, in milliseconds and unrounded — for the lane log,
    /// where the numbers are compared against each other and against the
    /// 250 ms join grace rather than read aloud.
    static func elapsedMs(since start: DispatchTime) -> UInt64 {
        (DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
    }

    /// Case, punctuation and whitespace folded away, so "All TextEdit windows
    /// are now forward." and "all textedit windows are now forward" compare
    /// equal. Non-alphanumerics become spaces (folds CONFIRM-style colons and
    /// curly quotes), runs collapse.
    static func normalizedForEcho(_ text: String) -> String {
        text.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
            .reduce(into: "") { out, ch in
                if ch == " ", out.hasSuffix(" ") { return }
                out.append(ch)
            }
            .trimmingCharacters(in: .whitespaces)
    }

    /// True when the candidate sentence says nothing the baseline hasn't —
    /// containment rather than equality, because the baseline holds the ack
    /// plus whatever else the turn already said.
    static func addsNothing(_ candidate: String, over baseline: String) -> Bool {
        let folded = normalizedForEcho(candidate)
        guard !folded.isEmpty else { return true }
        return normalizedForEcho(baseline).contains(folded)
    }

    /// The factual, capped epilogue a silently-settled routine leaves in
    /// history: enough that "what did you change?" stays answerable next
    /// turn, short enough that past actions can't steer future topics.
    static func doneMarker(outcomes: [LaneOutcome]) -> String {
        let skills = outcomes.map(\.skillName).joined(separator: ", ")
        // Honest tense, and TOTAL over what it is handed. A deferred spawn only
        // STARTED — "done" would let the next turn claim a completion nobody has
        // seen yet — and something that FAILED is not "done" in any tense.
        //
        // The failure arm is barely reachable today: the only caller that can
        // pass one a failing outcome is the deferred-spawn marker, because the
        // silent-settle gate upstream requires `allSatisfy(\.ok)` before it
        // writes the epilogue. That is the argument FOR closing it rather than
        // against. A partial predicate left standing is how the next caller
        // reintroduces the lie — which is precisely the history of
        // `fallbackFollowUpLine`, twenty lines down.
        let verb: String
        if outcomes.contains(where: { !$0.ok }) {
            verb = "couldn't"
        } else if outcomes.contains(where: \.deferred) {
            verb = "started"
        } else {
            verb = "done"
        }
        let brief = (outcomes.first?.summary ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let capped = brief.count > 160 ? String(brief.prefix(160)) + "…" : brief
        return capped.isEmpty ? "(\(verb): \(skills))" : "(\(verb): \(skills) — \(capped))"
    }

    /// "CONFIRM: <question>" → the question; falls back to a generic ask.
    static func confirmQuestion(fromOutcomes summaries: [String]) -> String {
        for summary in summaries.reversed() {
            guard let range = summary.range(of: "CONFIRM:") else { continue }
            let question = summary[range.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !question.isEmpty { return question }
        }
        return "There's an action waiting for your approval — should I go ahead?"
    }
}
