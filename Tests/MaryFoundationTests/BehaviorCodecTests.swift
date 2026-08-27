//
//  BehaviorCodecTests.swift
//  MaryFoundationTests
//
//  THE CODEC IS A FILE FORMAT, SO IT IS TESTED LIKE ONE.
//
//  Two properties carry everything else. BYTE-STABILITY: an episode encoded
//  twice must produce identical bytes, because the store appends one episode
//  per line and a dataset whose rows shift under re-encoding cannot be
//  diffed, deduplicated, or trusted. TOLERANCE: a file written by one build
//  must open in another, because these episodes are meant to outlive the
//  version that wrote them — that is the entire point of writing them.
//
//  The third property is subtler and is why `AmbientCapture` exists at all:
//  ABSENT IS NOT EMPTY. A turn that assembled no context and a turn that
//  assembled context and found nothing are different observations, and a
//  codec that collapsed them would quietly teach a future model that Mary
//  often acts blind.
//

import Foundation
import MaryFoundationTestSupport
import Testing
@testable import MaryFoundation

@Suite struct BehaviorCodecTests {

    // MARK: - Byte stability

    @Test func anEpisodeEncodesIdenticallyEveryTime() throws {
        let episode = BehaviorFixtures.typedIntoTextEdit
        let first = try BehavioralCodec.line(episode)
        let second = try BehavioralCodec.line(episode)
        #expect(first == second)
    }

    @Test func anEpisodeSurvivesARoundTripByteForByte() throws {
        let encoded = try BehavioralCodec.line(BehaviorFixtures.typedIntoTextEdit)
        let decoded = try BehavioralCodec.episode(from: encoded)
        #expect(decoded == BehaviorFixtures.typedIntoTextEdit)
        #expect(try BehavioralCodec.line(decoded) == encoded)
    }

    /// THE STORE APPENDS ONE EPISODE PER LINE. A pretty-printed encoder would
    /// corrupt the file it writes into, so the absence of newlines is a
    /// correctness property rather than a formatting preference.
    @Test func anEncodedEpisodeIsOneLine() throws {
        let encoded = try BehavioralCodec.line(BehaviorFixtures.typedIntoTextEdit)
        #expect(!encoded.contains(0x0A))
    }

    /// A file path in a document key should read as a path, not as an escape
    /// sequence — a dataset a person can read is a dataset a person can check.
    @Test func slashesAreNotEscaped() throws {
        var episode = BehaviorFixtures.typedIntoTextEdit
        episode.output.actions[0].containerKey = "/Users/someone/Notes/essay.txt"
        let text = try #require(
            String(data: try BehavioralCodec.line(episode), encoding: .utf8))
        #expect(text.contains("/Users/someone/Notes/essay.txt"))
        #expect(!text.contains("\\/"))
    }

    /// Dates round-trip through ISO-8601 rather than a float, so a row stays
    /// legible to anything that opens it.
    @Test func datesEncodeAsReadableTimestamps() throws {
        let text = try #require(
            String(
                data: try BehavioralCodec.line(BehaviorFixtures.typedIntoTextEdit),
                encoding: .utf8))
        #expect(text.contains("2026-08-27T"))
    }

    // MARK: - Tolerance

    /// An older reader must not choke on a newer writer's additions. This is
    /// the opposite posture from a `.mary` package, where an unknown key is a
    /// byte missing from a verified digest — see the codec headers.
    @Test func anUnknownKeyIsIgnoredRatherThanRefused() throws {
        var object = try episodeObject(BehaviorFixtures.typedIntoTextEdit)
        object["somethingFromTheFuture"] = ["nested": true]
        let decoded = try BehavioralCodec.decoder().decode(
            BehavioralEpisode.self,
            from: try JSONSerialization.data(withJSONObject: object))
        #expect(decoded.id == BehaviorFixtures.typedIntoTextEdit.id)
    }

    /// Everything with a sensible default may be absent. Only identity and
    /// the two timestamps that place an episode in time are required.
    @Test func anEpisodeDecodesFromItsRequiredFieldsAlone() throws {
        let json = Data("""
        {
          "id": "\(UUID().uuidString)",
          "openedAt": "2026-08-27T10:00:00Z",
          "input": {}
        }
        """.utf8)
        let decoded = try BehavioralCodec.decoder().decode(BehavioralEpisode.self, from: json)
        #expect(decoded.input.query.isEmpty)
        #expect(decoded.input.ambient == nil)
        #expect(decoded.output.actions.isEmpty)
        #expect(decoded.schema == BehavioralEpisode.schemaName)
        #expect(decoded.schemaVersion == 0, "an unversioned file must not claim this version")
    }

    /// A disposition this build has never heard of decodes as `.unknown`
    /// instead of failing the row. One future case must not make a whole
    /// day's dataset unreadable.
    @Test func anUnknownDispositionDecodesRatherThanThrowing() throws {
        var object = try episodeObject(BehaviorFixtures.typedIntoTextEdit)
        var output = try #require(object["output"] as? [String: Any])
        var actions = try #require(output["actions"] as? [[String: Any]])
        actions[0]["disposition"] = "quantumEntangled"
        output["actions"] = actions
        object["output"] = output

        let decoded = try BehavioralCodec.decoder().decode(
            BehavioralEpisode.self,
            from: try JSONSerialization.data(withJSONObject: object))
        #expect(decoded.output.actions[0].disposition == .unknown)
        #expect(decoded.output.actions[0].action.intention == "type_at_cursor")
    }

    @Test func anUnknownSealReasonDecodesRatherThanThrowing() throws {
        var object = try episodeObject(BehaviorFixtures.typedIntoTextEdit)
        object["sealedReason"] = "abducted"
        let decoded = try BehavioralCodec.decoder().decode(
            BehavioralEpisode.self,
            from: try JSONSerialization.data(withJSONObject: object))
        #expect(decoded.sealedReason == .unknown)
    }

    /// Places and slots are carried as tokens precisely so a renamed enum
    /// case cannot change what an old row means. An unrecognized token is
    /// just a word this build does not use.
    @Test func unrecognizedPlaceTokensPassThroughAsData() throws {
        var capture = BehaviorFixtures.textEditCapture
        capture.surfaces[0].place = "some-place-from-2030"
        capture.facts[0].slot = "a-slot-nobody-declared"
        let decoded = try roundTrip(capture)
        #expect(decoded.surfaces[0].place == "some-place-from-2030")
        #expect(decoded.facts[0].slot == "a-slot-nobody-declared")
    }

    // MARK: - Absent is not empty

    @Test func aNilCaptureAndAnEmptyCaptureAreDifferentRows() throws {
        var withoutCapture = BehaviorFixtures.typedIntoTextEdit
        withoutCapture.input.ambient = nil
        var withEmptyCapture = BehaviorFixtures.typedIntoTextEdit
        withEmptyCapture.input.ambient = .empty(mode: "relevance")

        let a = try BehavioralCodec.line(withoutCapture)
        let b = try BehavioralCodec.line(withEmptyCapture)
        #expect(a != b)
        #expect(try BehavioralCodec.episode(from: a).input.ambient == nil)
        #expect(try BehavioralCodec.episode(from: b).input.ambient?.isEmpty == true)
    }

    // MARK: - What the shapes carry

    /// The claim the whole codec rests on: one record answers *this frame,
    /// this plugin, this intention, these adapters* — the four things Bonnie
    /// needed six records and a live registry lookup to half-answer.
    @Test func oneRecordCarriesFramePluginIntentionAndAdapters() throws {
        let decoded = try BehavioralCodec.episode(
            from: try BehavioralCodec.line(BehaviorFixtures.typedIntoTextEdit))
        let action = try #require(decoded.output.actions.first).action

        #expect(action.intention == "type_at_cursor")
        #expect(action.skill.packageID.rawValue == "writing")
        #expect(action.skill.adapterID?.rawValue == "typer")
        #expect(action.adapters.map(\.rawValue) == ["typer"])

        let target = try #require(action.target)
        #expect(target.identity == "axtextarea|")
        #expect(target.frame.rect.width == 600)
        #expect(target.frame.center.x == 420)
    }

    /// A read that found nothing ran correctly. Keeping that out of the
    /// disposition is what stops "there are no notes open" being spoken as a
    /// failure — and what keeps `disposition` about whether the action ran.
    @Test func foundNothingIsNotAFailure() throws {
        let record = BehaviorFixtures.foundNothingRead
        #expect(record.disposition == .succeeded)
        #expect(record.foundNothing)
        #expect(record.disposition.didRun)
    }

    /// A parked action did NOT run, and its record must not imply otherwise.
    @Test func aParkedConfirmationDidNotRun() {
        #expect(!BehavioralDisposition.requestedConfirmation.didRun)
        #expect(!BehavioralDisposition.blocked.didRun)
    }

    /// A turn where Mary correctly did nothing is a real row, and `didAct`
    /// is how a training set separates the two populations.
    @Test func anEpisodeWithNoActionsIsValidAndDidNotAct() throws {
        var episode = BehaviorFixtures.typedIntoTextEdit
        episode.output = .init()
        #expect(!episode.didAct)
        #expect(try BehavioralCodec.episode(from: try BehavioralCodec.line(episode)) == episode)
    }

    /// An episode holding only a parked confirmation has not acted either —
    /// asking is not doing.
    @Test func anEpisodeThatOnlyAskedDidNotAct() {
        var episode = BehaviorFixtures.typedIntoTextEdit
        episode.output = .init(actions: [BehaviorFixtures.parkedDeletion])
        #expect(!episode.didAct)
    }

    /// The two halves of a confirmed action are joinable, which is the only
    /// thing that stops the dataset showing a question with no answer.
    @Test func aConfirmationLinksTwoEpisodes() throws {
        let (asked, ran) = BehaviorFixtures.confirmationPair
        let link = try #require(asked.output.actions.first?.confirmationID)
        #expect(ran.output.actions.first?.confirmationID == link)
        #expect(ran.input.priorEpisodeID == asked.id)
        #expect(asked.output.actions.first?.disposition == .requestedConfirmation)
        #expect(ran.output.actions.first?.disposition == .succeeded)
        #expect(
            asked.output.actions.first?.id != ran.output.actions.first?.id,
            "the ask and the run are separate invocations and must not share a run id")
    }

    /// A refusal is behaviour. A dataset containing only what Mary agreed to
    /// do would teach nothing about what she declines.
    @Test func aRefusalIsRecordedAsBlocked() throws {
        let record = BehavioralActionRecord.refused(
            id: "run-9",
            action: BehaviorFixtures.typeAction,
            reason: "I wasn't offered that this turn.")
        #expect(record.disposition == .blocked)
        #expect(!record.disposition.didRun)
        #expect(record.summary == "I wasn't offered that this turn.")
        #expect(record.finishedAt != nil)
    }

    // MARK: - Helpers

    private func episodeObject(_ episode: BehavioralEpisode) throws -> [String: Any] {
        let data = try BehavioralCodec.line(episode)
        return try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func roundTrip(_ capture: AmbientCapture) throws -> AmbientCapture {
        let data = try BehavioralCodec.encoder().encode(capture)
        return try BehavioralCodec.decoder().decode(AmbientCapture.self, from: data)
    }
}

// MARK: - Time, and why it is stored the way it is

@Suite struct BehaviorTimestampTests {

    /// THE PROPERTY THE WHOLE OUTPUT HALF RESTS ON: a sequence stays a
    /// sequence. Actions inside one turn land a few hundred milliseconds
    /// apart, so timestamps rounded to whole seconds — which is what the
    /// built-in ISO-8601 strategy does — would collapse them to identical
    /// stamps and destroy the order. This test would fail against that
    /// strategy, which is why the codec builds its own.
    @Test func actionsMillisecondsApartKeepTheirOrder() throws {
        let base = BehaviorFixtures.openedAt
        let offsets: [TimeInterval] = [0, 0.125, 0.25, 0.5]
        var episode = BehaviorFixtures.typedIntoTextEdit
        episode.output = .init(actions: offsets.enumerated().map { index, offset in
            var record = BehaviorFixtures.typedRecord
            record.id = "run-\(index)"
            record.startedAt = base.addingTimeInterval(offset)
            record.finishedAt = base.addingTimeInterval(offset + 0.0625)
            return record
        })

        let decoded = try BehavioralCodec.episode(from: try BehavioralCodec.line(episode))
        let stamps = decoded.output.actions.map(\.startedAt)
        #expect(Set(stamps).count == offsets.count, "timestamps collided — order is lost")
        #expect(stamps == stamps.sorted())
        #expect(decoded.output.actions.map(\.id) == ["run-0", "run-1", "run-2", "run-3"])
    }

    @Test func timestampsCarryMilliseconds() throws {
        let text = try #require(
            String(
                data: try BehavioralCodec.line(BehaviorFixtures.typedIntoTextEdit),
                encoding: .utf8))
        #expect(text.contains("2026-08-27T08:59:58.750Z"), "the capture stamp lost its fraction")
    }

    /// A stamp written without a fraction — by hand, or by an older build —
    /// still opens. Tolerance runs in both directions.
    @Test func aTimestampWithoutAFractionStillDecodes() throws {
        let json = Data("""
        {"id":"\(UUID().uuidString)","openedAt":"2026-08-27T09:00:00Z","input":{}}
        """.utf8)
        let decoded = try BehavioralCodec.decoder().decode(BehavioralEpisode.self, from: json)
        #expect(decoded.openedAt == Date(timeIntervalSince1970: 1_787_821_200))
    }

    /// Stamps are UTC regardless of where the machine is, so two people's
    /// datasets concatenate without a timezone argument.
    @Test func timestampsAreUTC() throws {
        let text = try #require(
            String(
                data: try BehavioralCodec.line(BehaviorFixtures.typedIntoTextEdit),
                encoding: .utf8))
        #expect(text.contains("09:00:00.000Z"))
        #expect(!text.contains("+0"), "a local-offset stamp leaked into the dataset")
    }
}

// MARK: - The realm, in a whole episode

/// The vocabulary the episode is written in: WORLD is Mary's own state, REALM
/// is what outside her could serve the need, PLACE is the where a realm
/// settled on. These pin the codec end of that — the tokens travel, and an
/// unresolved realm is a different row from a realm that found nobody.
@Suite struct EpisodeRealmTests {

    private func episode(_ realm: RealmCapture?) -> BehavioralEpisode {
        var episode = BehaviorFixtures.typedIntoTextEdit
        episode.input.ambient?.realm = realm
        return episode
    }

    @Test func anEpisodeCarriesTheRealmThroughARoundTrip() throws {
        let original = episode(BehaviorFixtures.writingRealm)
        let decoded = try BehavioralCodec.episode(from: try BehavioralCodec.line(original))
        #expect(decoded == original)

        let realm = try #require(decoded.input.ambient?.realm)
        #expect(realm.need.discipline == "writing")
        #expect(realm.candidates.count == 2, "the loser is kept — it is half the lesson")
        #expect(realm.place == "applications:textedit")
        #expect(realm.decidedBy == "ambientSource")
    }

    /// THE ROW MUST AGREE WITH THE PROMPT ABOUT THE WHERE. `lead` is the place
    /// the prompt actually used; `realm.place` is the place the resolver
    /// chose. Whenever both exist they are the same place, or the dataset
    /// teaches something the live system never did.
    @Test func theRealmsPlaceMatchesTheLead() throws {
        var withRealm = episode(BehaviorFixtures.writingRealm)
        withRealm.input.ambient?.lead = "applications:textedit"
        let ambient = try #require(withRealm.input.ambient)
        #expect(ambient.realm?.place == ambient.lead)
    }

    /// NO REALM is what every episode written before a resolver exists will
    /// carry, and it is honest: nobody worked out the candidates. It is not
    /// the same as a realm that looked and found nobody.
    @Test func anEpisodeWithoutARealmIsStillValid() throws {
        let plain = episode(nil)
        #expect(plain.input.ambient?.realm == nil)
        #expect(try BehavioralCodec.episode(from: try BehavioralCodec.line(plain)) == plain)

        let nowhere = episode(RealmCapture(need: NeedCapture(discipline: "writing")))
        #expect(try BehavioralCodec.line(plain) != (try BehavioralCodec.line(nowhere)))
    }

    /// A reader from before the realm existed still opens a row that has one.
    @Test func aRealmBearingRowDecodesLeniently() throws {
        let data = try BehavioralCodec.line(episode(BehaviorFixtures.writingRealm))
        var object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var input = try #require(object["input"] as? [String: Any])
        var ambient = try #require(input["ambient"] as? [String: Any])
        var realm = try #require(ambient["realm"] as? [String: Any])
        realm["somethingFromTheFuture"] = true
        ambient["realm"] = realm
        input["ambient"] = ambient
        object["input"] = input

        let decoded = try BehavioralCodec.decoder().decode(
            BehavioralEpisode.self,
            from: try JSONSerialization.data(withJSONObject: object))
        #expect(decoded.input.ambient?.realm?.place == "applications:textedit")
    }
}
