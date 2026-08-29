//
//  SeerUnitAnnotator.swift
//  MaryBrain
//
//  THE ANNOTATOR THAT ACTUALLY RUNS, because Mary's engine is always the
//  on-device one.
//
//  `InferenceUnitAnnotator` next door declines whenever its engine requires
//  exclusive generation — and Mary's does, every time, since the acting lane
//  runs locally in both modes. Left alone, that would mean no unit ever gets a
//  précis: every card structure-only, forever, for a reason that reads like a
//  bug and is not one.
//
//  So the hosted path gets its own annotator over Seer's chat. Summarising a
//  file needs no tools, which is the one thing Seer's chat cannot do, so this
//  is the rare job the hosted lane is strictly better at: it does not compete
//  with the user's turn for the local engine.
//
//  IT STILL DECLINES RATHER THAN QUEUES. When Seer is unreachable the answer
//  is nil, the unit deposits with its structure, and the ledger says why. A
//  background summariser that made the user wait would be a worse trade than
//  no summary at all.
//
//  THE SYSTEM PROMPT RIDES `instructions`, AND FORGETTING IT COST EVERY
//  SUMMARY IN HOSTED MODE. `InferenceUnitAnnotator.systemPrompt` is not
//  decoration — it is the JSON contract `parse` enforces on the way out. Sent
//  with `instructions: nil`, this annotator handed Seer a bare list of
//  declarations and no instruction, and Seer's chat is a PERSONA lane with
//  retrieval: it answered the way it answers anything, in prose about the
//  file. `parse` requires an object with a précis and at least one label, so
//  every one of those replies became nil — outcome `.failed`, and a Corpus
//  pane that read "structure only — the summariser returned nothing" for every
//  unit in the mode most installs actually run. Verified live against the
//  local server: the identical request with `instructions` set returns exactly
//  the required object, and without it returns a paragraph.
//

import Foundation
import MaryAmbient
import MaryFoundation
import os

public struct SeerUnitAnnotator: UnitAnnotating {

    private static let log = Logger(subsystem: "nyc.rao.mary", category: "corpus")

    private let chat: any SeerChatProviding

    public init(chat: any SeerChatProviding) {
        self.chat = chat
    }

    /// Never a policy refusal: this annotator's whole reason for existing is
    /// that it CAN answer. An unreachable server is a failure to try, which is
    /// a different thing and reads differently in the ledger.
    public nonisolated var refusesToAnnotate: Bool { false }

    public func annotate(_ request: UnitAnnotationRequest) async -> UnitAnnotation? {
        guard await chat.isReady() else {
            Self.log.debug("annotation skipped: seer not ready")
            return nil
        }
        let prompt = InferenceUnitAnnotator.prompt(for: request)
        var text = ""
        do {
            for try await event in chat.stream(
                messages: [SeerChatMessage(role: "user", content: prompt)],
                // THE SAME CONTRACT THE LOCAL PATH SENDS, over the slot this
                // transport carries a system prompt in. See the header.
                instructions: InferenceUnitAnnotator.systemPrompt
            ) {
                if case .token(let token) = event { text += token }
            }
        } catch {
            Self.log.error(
                "annotation failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        // THE SAME PARSER AS THE LOCAL PATH. Two annotators producing the same
        // shape must agree about what a malformed answer is, or a unit's card
        // depends on which engine happened to summarise it.
        guard let annotation = InferenceUnitAnnotator.parse(text) else {
            // THE DIAGNOSTIC THAT WAS MISSING, and its absence is why the
            // `instructions: nil` defect above survived: a reply that arrived
            // and did not parse logged NOTHING, so the ledger's `.failed` was
            // indistinguishable from a dead server. `.error` rather than
            // `.debug` because debug records are not persisted, and this is
            // precisely the line someone will go looking for afterwards.
            Self.log.error(
                """
                annotation unparsable for \(request.relativePath, privacy: .public): \
                \(text.count, privacy: .public) chars, begins \
                \(text.prefix(160).trimmingCharacters(in: .whitespacesAndNewlines), privacy: .public)
                """)
            return nil
        }
        return annotation
    }
}
