//
//  SeerUnitAnnotator.swift
//  MaryBrain
//
//  WHAT: Hosted unit annotator over Seer `/v1/complete`.
//  IN:   InferenceUnitAnnotator declines (Mary's engine is always exclusive)
//  OUT:  précis / labels via bounded complete route, not chat
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
