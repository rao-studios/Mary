//
//  VoiceTranscriber.swift
//  MaryVoice
//
//  WHAT: Per-utterance STT seam: begin → append… → finish.
//  IN:   VoicePipeline / WakeWordListener
//  OUT:  AppleSpeechTranscriber / AnalyzerSpeechTranscriber
//

import AVFoundation
import Foundation

public protocol VoiceTranscriber: AnyObject, Sendable {
    /// Ready the recognizer before the first utterance so `begin` does no cold
    /// work on the speech-start frame. Safe to call more than once.
    func prewarm(format: AVAudioFormat) async
    /// Prepare for one utterance in the mic's format.
    func begin(format: AVAudioFormat) async throws
    /// Feed one captured buffer.
    func append(_ buffer: AVAudioPCMBuffer) async
    /// Live partials for this utterance. May be empty until `finish()`.
    func partials() async -> AsyncStream<String>
    /// Close the utterance and return the final transcript.
    func finish() async throws -> String
    /// Abandon the in-flight utterance.
    func cancel() async
}

extension VoiceTranscriber {
    public func prewarm(format: AVAudioFormat) async {}
}

public enum TranscriberError: LocalizedError {
    case notAuthorized
    case recognizerUnavailable
    case noSpeech

    public var errorDescription: String? {
        switch self {
        case .notAuthorized: return "Speech recognition was not authorized."
        case .recognizerUnavailable: return "No speech recognizer is available for this locale."
        case .noSpeech: return "No speech was recognized."
        }
    }
}
