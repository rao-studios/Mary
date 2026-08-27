//
//  ConversationStreamViewModel.swift
//  Mary
//
//  Display tempo for the in-flight utterance, ported near-verbatim from
//  Gita's StoryStreamViewModel. Granite owns durable state; this object owns
//  how fast the reader sees it: tokens land in a buffer that drains
//  char-by-char at 15–25 ms, past Granite's 200 ms @Store debounce (the view
//  feeds it from `relay.objectWillChange` directly).
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
            // SAME ROW, SHORTER TEXT ⇒ the reply was thrown away and restarted
            // under the same identity. `.turnSuperseded` and `.userAmended`
            // both blank the bubble's text in place and re-arm isStreaming
            // without minting a new id, so the id check above cannot see it.
            //
            // Left alone, `bufferedCount` still held the OLD reply's length,
            // and `bufferNewChars` only ever appends what lies past it — so
            // the replacement's opening characters were swallowed, and a
            // replacement shorter than the original never cleared the
            // watermark at all: `streamedText` stayed empty for the whole
            // turn and the row rendered as a blank bubble until handoff.
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
