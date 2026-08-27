//
//  BehaviorFixtures.swift
//  MaryFoundationTestSupport
//
//  ONE REALISTIC EPISODE, BUILT IN SWIFT.
//
//  The episode below is what Mary's first real turn should look like: the
//  user asks her to write something into TextEdit, the ambient capture holds
//  the TextEdit window she was looking at with its text area and frame, and
//  the output is one `type_at_cursor` action naming the typer adapter and the
//  element it typed into. Every test that needs "an episode" starts here and
//  changes the one field it is about, so a failure names one cause.
//
//  FIXED DATES AND UUIDS, deliberately. A byte-stability test cannot use
//  `Date()` or `UUID()` — it would pass for the wrong reason on the first run
//  and fail on the second. These constants are also what makes an encoded
//  episode diffable by eye when a schema change lands.
//
//  THE FRACTIONAL OFFSETS ARE ALL EXACT BINARY FRACTIONS (.5, .25, .125),
//  which is not fussiness. The codec stores millisecond precision, and a Date
//  built from something like `-1.2` is a Double that is NOT exactly
//  1,000ths — it formats to `.800` and parses back to a value one ulp away,
//  so a round-trip equality test fails for a reason that has nothing to do
//  with the codec. Offsets that land on exact binary fractions round-trip
//  bit-for-bit, so the test measures what it claims to.
//

import Foundation
import MaryFoundation

public enum BehaviorFixtures {

    // MARK: - Fixed moments

    /// The turn's own identity; an episode's id is the user turn's id.
    public static let episodeID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    public static let priorEpisodeID = UUID(uuidString: "00000000-1111-2222-3333-444444444444")!
    public static let confirmationID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!

    public static let openedAt = Date(timeIntervalSince1970: 1_787_821_200)  // 2026-08-27T09:00:00Z
    public static let capturedAt = openedAt.addingTimeInterval(-1.25)
    public static let finishedAt = openedAt.addingTimeInterval(2.5)

    // MARK: - Geometry

    /// The TextEdit document's text area — where the typing landed.
    ///
    /// `center` is passed rather than derived: MaryFoundation carries no
    /// geometry math at all (the projector computes it once so no consumer
    /// re-derives it differently), so a fixture supplies it the same way a
    /// real producer does.
    public static var textAreaFrame: AXFrame {
        AXFrame(
            space: .axGlobalTopLeft,
            rect: .init(x: 120, y: 180, width: 600, height: 420),
            center: .init(x: 420, y: 390),
            inWindow: .init(x: 0, y: 44, width: 600, height: 420),
            screen: .init(index: 0, rect: .init(x: 0, y: 0, width: 1920, height: 1080)),
            isClipped: false,
            capturedAt: capturedAt)
    }

    public static var windowFrame: AXFrame {
        AXFrame(
            space: .axGlobalTopLeft,
            rect: .init(x: 120, y: 136, width: 600, height: 464),
            center: .init(x: 420, y: 368),
            screen: .init(index: 0, rect: .init(x: 0, y: 0, width: 1920, height: 1080)),
            capturedAt: capturedAt)
    }

    /// The acted element. `identity` is `role.lowercased() + "|" +
    /// normalized(label)` — a text area carries no label, hence the bare
    /// trailing separator, which is the real spelling and not an oversight.
    public static var textArea: AXElementRecord {
        AXElementRecord(
            identity: "axtextarea|",
            ordinal: 1,
            role: "AXTextArea",
            label: "",
            kind: "text area",
            containerTrail: ["Essay"],
            isEnabled: true,
            isFocused: true,
            appName: "TextEdit",
            pid: 4321,
            windowTitle: "Essay",
            frame: textAreaFrame)
    }

    // MARK: - The input half

    /// What Mary could see: one TextEdit window, one fact about it, no
    /// selection.
    public static var textEditCapture: AmbientCapture {
        AmbientCapture(
            mode: "focusedWorld",
            lead: "textedit",
            surfaces: [
                SurfaceCapture(
                    place: "textedit",
                    application: .init(
                        name: "TextEdit", bundleID: "com.apple.TextEdit", pid: 4321),
                    windowTitle: "Essay",
                    windowFrame: windowFrame,
                    elements: [textArea],
                    capturedAt: capturedAt)
            ],
            facts: [
                FactCapture(
                    place: "textedit",
                    slot: "file",
                    text: "Essay — 1,840 characters, with 2 other notes open I haven't read.",
                    ageSeconds: 3.5,
                    provenance: "poll")
            ],
            renderedSurfaceLines: [
                "TextEdit is frontmost — Essay, a text area and 4 other controls."
            ],
            renderedBlocks: [
                "Essay — 1,840 characters, with 2 other notes open I haven't read."
            ])
    }

    // MARK: - The output half

    /// The Skill that answered: writing's `type_at_cursor`, fulfilled by the
    /// typer adapter. A runtime-owned provider, since the typer is a generic
    /// adapter Mary ships rather than one a package brought with it.
    public static var typeAtCursorSkill: AbilitySkillReference {
        AbilitySkillReference(
            packageID: "writing",
            packageVersion: "1.0.0",
            abilityID: "writing",
            abilityTitle: "Writing",
            abilityTint: "#4A6FA5",
            skillID: "writing.type-at-cursor",
            skillTitle: "Type at cursor",
            invocationName: "type_at_cursor",
            adapterID: "typer",
            bindingOperation: "type_at_cursor",
            provider: .init(
                pluginClass: .runtime,
                pluginID: "typer",
                pluginTitle: "Typer",
                applicationID: "textedit"))
    }

    public static var typeAction: BehavioralAction {
        BehavioralAction(
            intention: "type_at_cursor",
            argumentsJSON: #"{"mode":"compose","text":"The tide came in overnight."}"#,
            skill: typeAtCursorSkill,
            target: textArea,
            adapters: ["typer"])
    }

    public static var typedRecord: BehavioralActionRecord {
        BehavioralActionRecord(
            id: "run-1",
            action: typeAction,
            disposition: .succeeded,
            summary: "Typed 27 characters into Essay.",
            undoable: true,
            containerKey: "W1",
            startedAt: openedAt.addingTimeInterval(0.5),
            finishedAt: finishedAt)
    }

    /// A read that ran correctly and found nothing — succeeded, not failed.
    public static var foundNothingRead: BehavioralActionRecord {
        BehavioralActionRecord(
            id: "run-2",
            action: BehavioralAction(
                intention: "search_notes",
                argumentsJSON: #"{"query":"tide"}"#,
                skill: typeAtCursorSkill,
                adapters: ["prose-surface"]),
            disposition: .succeeded,
            summary: "Nothing in the open notes mentions that.",
            foundNothing: true,
            startedAt: openedAt,
            finishedAt: openedAt.addingTimeInterval(0.25))
    }

    /// An action parked awaiting a spoken go-ahead. It did NOT run.
    public static var parkedDeletion: BehavioralActionRecord {
        BehavioralActionRecord(
            id: "run-3",
            action: BehavioralAction(
                intention: "delete_passage",
                argumentsJSON: #"{"passage":"S1"}"#,
                skill: typeAtCursorSkill,
                target: textArea,
                adapters: ["prose-surface"]),
            disposition: .requestedConfirmation,
            summary: "Delete the opening paragraph of Essay?",
            confirmationID: confirmationID,
            startedAt: openedAt,
            finishedAt: openedAt.addingTimeInterval(0.125))
    }

    // MARK: - Whole episodes

    /// THE CANONICAL EPISODE: asked to write, saw TextEdit, typed into it.
    public static var typedIntoTextEdit: BehavioralEpisode {
        BehavioralEpisode(
            id: episodeID,
            openedAt: openedAt,
            sealedAt: finishedAt,
            sealedReason: .completed,
            input: .init(
                query: "write that the tide came in overnight",
                ambient: textEditCapture,
                priorEpisodeID: priorEpisodeID),
            output: .init(actions: [typedRecord]),
            provenance: .init(engine: "local", lane: "dual", appVersion: "0.1.0"))
    }

    /// A CONFIRMED ACTION SPANS TWO TURNS: the first asks, the second runs.
    /// Linked by `confirmationID`, chained by `priorEpisodeID`, and carrying
    /// two different run ids because they are two different invocations.
    public static var confirmationPair: (asked: BehavioralEpisode, ran: BehavioralEpisode) {
        let asked = BehavioralEpisode(
            id: episodeID,
            openedAt: openedAt,
            sealedAt: openedAt.addingTimeInterval(0.5),
            sealedReason: .completed,
            input: .init(
                query: "delete the first paragraph",
                ambient: textEditCapture,
                priorEpisodeID: priorEpisodeID),
            output: .init(actions: [parkedDeletion]),
            provenance: .init(engine: "local", lane: "dual", appVersion: "0.1.0"))

        var ranRecord = parkedDeletion
        ranRecord.id = "decision-1"
        ranRecord.disposition = .succeeded
        ranRecord.summary = "Deleted the opening paragraph of Essay."
        ranRecord.undoable = true

        // The confirming turn is a bare "yes": deterministic, so no prompt is
        // built and no context is assembled. `ambient: nil` is the honest
        // record of that — the context that earned the action lives in the
        // asking episode, reachable by the link.
        let ran = BehavioralEpisode(
            id: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!,
            openedAt: openedAt.addingTimeInterval(6),
            sealedAt: openedAt.addingTimeInterval(7),
            sealedReason: .completed,
            input: .init(query: "yes", ambient: nil, priorEpisodeID: episodeID),
            output: .init(actions: [ranRecord]),
            provenance: .init(engine: "local", lane: "dual", appVersion: "0.1.0"))

        return (asked, ran)
    }
}
