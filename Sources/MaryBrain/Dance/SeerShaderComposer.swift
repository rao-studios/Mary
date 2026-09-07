//
//  SeerShaderComposer.swift
//  MaryBrain
//
//  WHAT: Hosted shader composer over Seer `/v1/complete`.
//  IN:   DanceEngine, through the DanceComposing seam
//  OUT:  DanceComposition, or a DanceComposerError with the reason in it
//  PIN:  THE BRAIN CONFORMS, THE RUNTIME INJECTS. MaryPlugin never sees Seer.
//        A hint from the emotion classifier and the last few spoken lines are
//        what make "how are you feeling" an answer rather than a picture.
//

import Foundation
import MaryPlugin
import MaryVoice
import os

public struct SeerShaderComposer: DanceComposing {

    private static let log = Logger(subsystem: "nyc.rao.mary", category: "dance")

    private let complete: any SeerCompleteProviding
    private let recentLines: @Sendable () async -> [String]
    private let now: @Sendable () -> Date

    public init(
        complete: any SeerCompleteProviding,
        recentLines: @escaping @Sendable () async -> [String] = { [] },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.complete = complete
        self.recentLines = recentLines
        self.now = now
    }

    public func isReady() async -> Bool {
        await complete.isReady()
    }

    public func compose(_ brief: DanceBrief) async throws -> DanceComposition {
        var brief = brief
        if brief.moodHint == nil {
            let emotion = EmotionClassifier.classify(brief.utterance)
            if emotion != .neutral { brief.moodHint = "the question reads as \(emotion.rawValue)" }
        }
        let prompt = DanceShaderPrompt.prompt(
            for: brief, recentLines: await recentLines(), now: now())
        let text: String
        do {
            text = try await complete.complete(
                instructions: DanceShaderPrompt.systemPrompt,
                messages: [SeerChatMessage(role: "user", content: prompt)],
                maxTokens: SeerCompleteBudget.shader)
        } catch let error as SeerCompleteError {
            switch error {
            case .notAuthenticated:
                throw DanceComposerError.unavailable("I'm not signed in to Seer.")
            case .emptyReply:
                throw DanceComposerError.unparsable("Seer answered with nothing.")
            case .http, .unreachable:
                Self.log.error("shader composition failed: \(error.localizedDescription, privacy: .public)")
                throw DanceComposerError.failed(error.localizedDescription)
            }
        } catch {
            Self.log.error("shader composition failed: \(error.localizedDescription, privacy: .public)")
            throw DanceComposerError.failed(error.localizedDescription)
        }
        guard let composition = DanceShaderPrompt.parse(text) else {
            Self.log.error(
                "shader reply unparsable: \(text.count, privacy: .public) chars, begins \(text.prefix(120), privacy: .public)")
            throw DanceComposerError.unparsable("the reply held no shader.")
        }
        return composition
    }
}
