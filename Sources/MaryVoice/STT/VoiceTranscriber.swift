//
//  VoiceTranscriber.swift
//  MaryVoice
//
//  How the user's voice becomes words. One transcriber instance lives for the
//  session; each utterance runs begin → append… → finish. (Named
//  VoiceTranscriber to stay clear of Apple's SpeechTranscriber API and
//  FleetAudio's file-based AudioTranscriber.)
//

import AVFoundation
import Foundation

public protocol VoiceTranscriber: AnyObject, Sendable {
    /// Prepare for one utterance in the mic's format.
    func begin(format: AVAudioFormat) async throws
    /// Feed one captured buffer.
    func append(_ buffer: AVAudioPCMBuffer) async
    /// Live partial transcripts for this utterance.
    ///
    /// MAY BE EMPTY, and a caller must not treat silence here as silence in
    /// the room: an utterance-final backend has nothing to say until
    /// `finish()`. Only the transcript that call returns is load-bearing.
    func partials() async -> AsyncStream<String>
    /// Close the utterance and return the final transcript.
    func finish() async throws -> String
    /// Abandon the in-flight utterance.
    func cancel() async
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
