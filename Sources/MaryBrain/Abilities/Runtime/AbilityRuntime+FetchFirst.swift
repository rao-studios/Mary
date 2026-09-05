//
//  AbilityRuntime+FetchFirst.swift
//  MaryBrain
//
//  WHAT: MARY'S OWN READS — what she goes and looks at before
//        either lane speaks.
//  IN:   the leading place's declared read, else the screen
//  OUT:  a passage, or nil when nothing was worth serving
//  PIN:  A pre-read is not a model invocation. It skips the offer ledger and
//        nothing else; every hard gate still runs. See `RuntimeRead`.
//
import Foundation

extension AbilityRuntime {

    /// MARY'S OWN READ, not the model's call. Set only by the fetch-first
    /// members of this file (`readNamedPart`, `lookAtScreen`, `dispatchSummary`)
    /// while they dispatch, and read by exactly one gate — `offerLedgerFailure`.
    ///
    /// WHY IT EXISTS. The offer ledger is the roster's authorization claim over
    /// the MODEL: a Skill the roster did not offer this turn must not be
    /// invocable by something that read its name out of a schema. A pre-read is
    /// not that. Mary decided, from the route and the world, to go and look at
    /// the work in front of the user before she speaks — and the roster is
    /// scored against the user's WORDS, so "what do you think about this code"
    /// (which embeds nowhere near "Read the Buffer") withheld `read_buffer` and
    /// `read_selection` from her own eyes. She then answered a question about
    /// code having read none, which is where "paste the code here" came from,
    /// with a live highlight on screen.
    ///
    /// The hard gate is untouched: `dispatchEligibilityFailure` still runs, so
    /// model exposure, capability policy, permissions, readiness, perception
    /// and mutation authorization all still decide whether the read may happen.
    ///
    /// BRIDGES TO THE RECORD'S OWN PROVENANCE (`ActionInitiator`) rather than
    /// carrying a second, parallel flag — the chokepoint stamps every record
    /// with `ActionInitiator.current` regardless, so a pre-read's provenance
    /// and the fact that it may skip the ledger are one and the same bit, not
    /// two that could drift apart. Binding happens via `ActionInitiator.$current`
    /// directly at the three fetch-first call sites; this is the read side only.
    enum RuntimeRead {
        static var isFetchFirst: Bool { ActionInitiator.current == .maryRead }
    }

    /// Fetch-first: leading world's targeted read for `phrase`, same summary the model would see.
    public func readNamedPart(_ phrase: String) async -> String? {
        let wanted = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        // Container the turn named first, then the leading world.
        let owner = world.store.referent()?.place.memoryToken ?? focusProvider?()
        guard !wanted.isEmpty,
              let owner,
              let targeted = targetedReads[owner],
              skillBindings.contains(where: { $0.name == targeted.binding }),
              let arguments = try? JSONSerialization.data(
                withJSONObject: [targeted.parameter: wanted], options: [.sortedKeys]),
              let json = String(data: arguments, encoding: .utf8)
        else { return nil }
        let outcome = await ActionInitiator.$current.withValue(.maryRead) {
            await dispatch(name: targeted.binding, argumentsJSON: json)
        }
        guard outcome.ok, !outcome.foundNothing else { return nil }
        let summary = outcome.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.isEmpty ? nil : summary
    }

    /// Pre-lane look — `readNamedPart`'s sibling for sight.
    /// PIN: an eyed world with a targeted read in hand declines look —
    /// a screenshot of a surface Mary can already read exactly (source,
    /// symbol, buffer) is a picture of text, not new sight.
    public func wouldServeLook() -> Bool {
        guard skillBindings.contains(where: { $0.name == Self.lookSkillName }) else {
            return false
        }
        if let owner = focusProvider?(), targetedReads[owner] != nil { return false }
        return true
    }

    /// A one-line summary this short is a RECEIPT ("Looking at Foo.swift in
    /// Proj.") — an acknowledgment that something was found, never the thing
    /// itself. Fetch-first must not serve a receipt as sight: the user asked
    /// about their work, not confirmation a file exists.
    static func isReceipt(_ summary: String) -> Bool {
        !summary.contains("\n") && summary.count < 80
    }

    /// Fetch-first: highlight → selection read, then the leading place's OWN
    /// declared discipline — a coding surface holds a live BUFFER
    /// (read_buffer), a writing surface holds the DOCUMENT (read_document) —
    /// else look. `current_file` is deliberately absent from this ladder:
    /// its summary is a receipt, not code or prose, and serving it as sight
    /// used to answer a work question having read no work.
    /// Returns whether the passage came from a genuine read (vs. a look),
    /// so the caller can tell Lane B what is already in hand.
    public func fetchDeclaredEditorSight(
        query: String?
    ) async -> (passage: String, isRead: Bool)? {
        // THE TURN ALREADY DECIDED THIS. Nil is an answer — the route rejected the
        // standing selection — so re-reading the store would hand it straight back.
        let snapshot: AmbientWorld.Snapshot?
        if let routed = AmbientRouteTurnContext.state?.current() {
            snapshot = routed.routedWorld
        } else {
            snapshot = world.snapshot()
        }
        let highlight = snapshot?.selectedText?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if snapshot?.isDirectReference == true, !highlight.isEmpty {
            // A short highlight genuinely IS the passage — receipts allowed.
            if let passage = await dispatchSummary("read_selection", rejectingReceipts: false) {
                return (passage, true)
            }
            return (highlight, true)
        }
        if snapshot?.place.isApplication == true {
            if snapshot?.place.focus != .writing,
               let passage = await dispatchSummary("read_buffer") {
                return (passage, true)
            }
            if let passage = await dispatchSummary("read_document") {
                return (passage, true)
            }
        }
        guard let passage = await lookAtScreen(query) else { return nil }
        return (passage, false)
    }

    /// FETCH-FIRST FOR THE CRAFT: read the unit the user is inside, and trace
    /// what reaches it, before either lane speaks.
    ///
    /// WHICH TURNS. Not the ones that asked for an ACTION — those have a
    /// receipt to report and no time to spend — and not an edit, which already
    /// located its own target. Everything else that happens inside work Mary
    /// follows is fair game, including the plainest question there is: the
    /// route calls "what do you think about this code" a CONVERSE turn about
    /// as often as it calls it a perceive one, and that classification is
    /// exactly what used to decide whether Mary read the code before answering
    /// a question about it.
    ///
    /// WHICH ORDER, and it matters. On a turn that already reads as being
    /// about the work, the unit comes first and the trace supports it. On a
    /// turn the router thinks is small talk, the TRACE goes first and has to
    /// find something real before the unit is read at all — so an idle remark
    /// in an editor stays an idle remark, and only a sentence that actually
    /// lands somewhere in their project turns into a read.
    public func fetchAwareness(query: String) async -> AwarenessSight? {
        func live(_ candidate: AwarenessRead) -> Bool {
            skillBindings.contains { $0.name == candidate.unit }
                && skillBindings.contains { $0.name == candidate.surroundings }
        }
        // THE LEADING WORLD'S OWN READ FIRST.
        //
        // PIN: WITH ONE FACULTY THIS WAS A LIST OF ONE AND `first` WAS AN
        // ANSWER. A browser declares an awareness read now too, so `first`
        // became catalog order — which would read a page while somebody asks
        // about the code in front of them, or the reverse. The lead place
        // already decides every other fetch-first road (see `readNamedPart`
        // and `wouldServeLook`); it decides this one too.
        let owner = world.store.referent()?.place.memoryToken ?? focusProvider?()
        let read = owner
            .flatMap { awarenessReadsByOwner[$0] }
            .flatMap { live($0) ? $0 : nil }
            ?? awarenessReads.first(where: live)
        guard let read else { return nil }

        let route = AmbientRouteTurnContext.state?.current() ?? world.store.route()
        // The turn already decided it wants something done. Leave it alone.
        if route?.isActionTurn == true || route?.verdicts.editIntent != nil { return nil }

        let aboutTheWork: Bool
        switch route?.intent {
        case .perceive, .ask, .architect:
            aboutTheWork = true
        case .converse, .none:
            // A REMARK MAY STILL BE ABOUT THE WORK — "what do you think about
            // THIS" is scored as conversation and is not. But it has to point
            // at something: a deictic word, or a highlight the turn accepted.
            // Idle company in an editor stays idle company, and costs nothing.
            guard route?.verdicts.isDeictic == true
                || route?.routedSelectionWorld != nil
            else { return nil }
            aboutTheWork = false
        default:
            return nil
        }

        var sight = AwarenessSight()
        if aboutTheWork {
            sight.unit = await dispatchSummary(read.unit)
            sight.surroundings = await dispatchSummary(
                read.surroundings, arguments: ["query": query], rejectingReceipts: false)
        } else {
            // EARN THE READ. Nothing traced, nothing read.
            sight.surroundings = await dispatchSummary(
                read.surroundings, arguments: ["query": query], rejectingReceipts: false)
            if sight.surroundings != nil {
                sight.unit = await dispatchSummary(read.unit)
            }
        }
        return sight.isEmpty ? nil : sight
    }

    public func lookAtScreen(_ query: String?) async -> String? {
        guard wouldServeLook() else { return nil }
        var arguments: [String: String] = [:]
        if let query, !query.isEmpty { arguments["query"] = query }
        guard let data = try? JSONSerialization.data(
                withJSONObject: arguments, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        let outcome = await ActionInitiator.$current.withValue(.maryRead) {
            await dispatch(name: Self.lookSkillName, argumentsJSON: json)
        }
        guard outcome.ok, !outcome.foundNothing else { return nil }
        let summary = outcome.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.isEmpty ? nil : summary
    }

    /// One fetch-first read, by binding name, with optional arguments.
    /// PIN: the ONLY caller family of `RuntimeRead.isFetchFirst` besides
    ///      `readNamedPart` and `lookAtScreen` — see that enum's header.
    private func dispatchSummary(
        _ name: String,
        arguments: [String: String] = [:],
        rejectingReceipts: Bool = true
    ) async -> String? {
        guard skillBindings.contains(where: { $0.name == name }) else { return nil }
        let json = (try? JSONSerialization.data(
            withJSONObject: arguments, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let outcome = await ActionInitiator.$current.withValue(.maryRead) {
            await dispatch(name: name, argumentsJSON: json)
        }
        guard outcome.ok, !outcome.foundNothing else { return nil }
        let summary = outcome.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return nil }
        guard !rejectingReceipts || !Self.isReceipt(summary) else { return nil }
        return summary
    }
}
