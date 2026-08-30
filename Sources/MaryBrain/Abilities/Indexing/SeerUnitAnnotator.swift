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
//  So the hosted path gets its own annotator over Seer's `/v1/complete`.
//  Summarising a file needs no tools, no memory, and no contributions — the
//  things Seer's chat lane always adds. `/v1/chat/completions` is a PERSONA
//  lane with Totem RAG and a trailing Gita contribution; handed a JSON
//  contract it still answered in prose about the file. `parse` requires an
//  object with a précis and at least one label, so every one of those replies
//  became nil. This annotator uses the bounded complete route instead, the
//  sibling of `/v1/vision/look`: system + user, one JSON body, no SSE trailer.
//
//  IT STILL DECLINES RATHER THAN QUEUES. When Seer is unreachable the answer
//  is nil, the unit deposits with its structure, and the ledger says why. A
//  background summariser that made the user wait would be a worse trade than
//  no summary at all.
//
//  THE SYSTEM PROMPT RIDES `instructions`, AND FORGETTING IT COST EVERY
//  SUMMARY IN HOSTED MODE. `InferenceUnitAnnotator.systemPrompt` is not
//  decoration — it is the JSON contract `parse` enforces on the way out.
//

import Foundation
import MaryAmbient
import MaryFoundation
import os

public struct SeerUnitAnnotator: UnitAnnotating {

    private static let log = Logger(subsystem: "nyc.rao.mary", category: "corpus")

    private let complete: any SeerCompleteProviding

    public init(complete: any SeerCompleteProviding) {
        self.complete = complete
    }

    /// Never a policy refusal: this annotator's whole reason for existing is
    /// that it CAN answer. An unreachable server is a failure to try, which is
    /// a different thing and reads differently in the ledger.
    public nonisolated var refusesToAnnotate: Bool { false }

    public func annotate(_ request: UnitAnnotationRequest) async -> UnitAnnotation? {
        if case .annotated(let annotation) = await annotationAttempt(request) {
            return annotation
        }
        return nil
    }

    public func annotationAttempt(
        _ request: UnitAnnotationRequest
    ) async -> UnitAnnotationAttempt {
        guard await complete.isReady() else {
            Self.log.debug("annotation skipped: seer not ready")
            return .seerUnavailable
        }
        let prompt = InferenceUnitAnnotator.prompt(for: request)
        let text: String
        do {
            text = try await complete.complete(
                instructions: InferenceUnitAnnotator.systemPrompt,
                messages: [SeerChatMessage(role: "user", content: prompt)])
        } catch let error as SeerCompleteError {
            switch error {
            case .notAuthenticated:
                return .seerUnavailable
            case .emptyReply:
                return .empty
            case .http, .unreachable:
                Self.log.error(
                    "annotation failed: \(error.localizedDescription, privacy: .public)")
                return .failed(error.localizedDescription)
            }
        } catch {
            Self.log.error(
                "annotation failed: \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .empty
        }
        guard let annotation = InferenceUnitAnnotator.parse(text) else {
            Self.log.error(
                """
                annotation unparsable for \(request.relativePath, privacy: .public): \
                \(text.count, privacy: .public) chars, begins \
                \(text.prefix(160).trimmingCharacters(in: .whitespacesAndNewlines), privacy: .public)
                """)
            return .unparsable
        }
        return .annotated(annotation)
    }
}
