//
//  ConversationStreamViewModel.swift
//  Mary
//
//  WHAT: Display tempo for the in-flight utterance (char-by-char 15–25 ms).
//  IN:   relay.objectWillChange (past Granite 200 ms @Store debounce)
//  OUT:  StreamingUtteranceView
//

import SwiftUI
import MaryRuntime

@MainActor
final class ConversationStreamViewModel: ObservableObject {
    enum Phase {
        case idle
        case thinking
        case streaming
    }

    @Published var phase: Phase = .idle
    @Published var streamedText: String = ""
    @Published var streamingUtteranceId: UUID?

    var characterDelayMs: Double = 15.0
    var characterJitterMs: Double = 10.0

    private var trackedUtteranceId: UUID?
    private var tokenBuffer: String = ""
    private var bufferedCount: Int = 0
    private var isStreamFinished: Bool = false
    private var isDraining: Bool = false
    private var drainTask: Task<Void, Never>?

    func update(utterances: [Utterance]) {
        guard let last = utterances.last else {
            trackedUtteranceId = nil
            streamingUtteranceId = nil
            resetStreamingState()
            phase = .idle
            return
        }

        if last.id != trackedUtteranceId {
            trackedUtteranceId = last.id
            resetStreamingState()
            streamedText = ""

            // Already complete on first sight ⇒ restored from disk; no reveal.
            if !last.isStreaming, !last.isThinking, !last.text.isEmpty {
                streamingUtteranceId = nil
                phase = .idle
                return
            }
        } else if last.text.count < bufferedCount {
            // Same row, shorter text: reply restarted in place (supersede/amend). Reset the drain watermark.
            resetStreamingState()
            streamedText = ""
        }

        if last.isThinking || last.isStreaming {
            streamingUtteranceId = last.id
            if last.text.isEmpty {
                phase = .thinking
            } else {
                phase = .streaming
                bufferNewChars(from: last.text)
                startDrainingIfNeeded()
            }
        } else if phase != .idle {
            // Stream finished — drain whatever is left, then hand off to the
            // persistent utterance rendering.
            bufferNewChars(from: last.text)
            isStreamFinished = true
            startDrainingIfNeeded()
        }
    }

    private func bufferNewChars(from text: String) {
        guard text.count > bufferedCount else { return }
        let startIdx = text.index(text.startIndex, offsetBy: bufferedCount)
        tokenBuffer += String(text[startIdx...])
        bufferedCount = text.count
    }

    private func startDrainingIfNeeded() {
        guard !isDraining else { return }
        isDraining = true
        drainTask = Task { [weak self] in
            defer { self?.isDraining = false }
            while !Task.isCancelled {
                guard let self else { break }

                if self.tokenBuffer.isEmpty {
                    if self.isStreamFinished {
                        self.phase = .idle
                        self.streamedText = ""
                        self.streamingUtteranceId = nil
                        break
                    }
                    try? await Task.sleep(nanoseconds: 5_000_000)
                    continue
                }

                let char = self.tokenBuffer.removeFirst()
                self.streamedText += String(char)

                let delay = self.characterDelayMs + Double.random(in: 0...self.characterJitterMs)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000))
            }
        }
    }

    private func resetStreamingState() {
        drainTask?.cancel()
        drainTask = nil
        isDraining = false
        tokenBuffer = ""
        bufferedCount = 0
        isStreamFinished = false
    }
}
