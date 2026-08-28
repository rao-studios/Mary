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
                instructions: nil
            ) {
                if case .token(let token) = event { text += token }
            }
        } catch {
            Self.log.debug("annotation failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        // THE SAME PARSER AS THE LOCAL PATH. Two annotators producing the same
        // shape must agree about what a malformed answer is, or a unit's card
        // depends on which engine happened to summarise it.
        return InferenceUnitAnnotator.parse(text)
    }
}
