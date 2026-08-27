//
//  MaryBrain+Dictation.swift
//  MaryBrain
//
//  THE VOCABULARY OF A HELD DICTATION SESSION — a pure utterance classifier,
//  and the turn-loop halves that use it.
//
//  A session owns every utterance while it is held, so this file decides the
//  only thing that could take one back: whether the user is writing prose or
//  speaking to Mary. Get that wrong in the permissive direction and a novel
//  gains the sentence "Mary stop writing"; get it wrong in the strict
//  direction and the session cannot be closed by voice at all. The rules below
//  are shaped by which of those two is worse — and it is the second, because
//  it has no exit.
//

import MaryAmbient
import MaryAdapters
import MaryVoice
import Foundation

extension MaryBrain {

    // MARK: - The vocabulary

    enum DictationControl: Equatable, Sendable {
        case newParagraph
        case newLine
        case scratch
        case stop
    }

    /// The same normalization `bareCorrection` uses, for the same reason: a
    /// spoken sentence arrives with punctuation nobody chose.
    static func normalizedUtterance(_ text: String) -> String {
        text.lowercased()
            .filter { $0.isLetter || $0.isWhitespace }
            .split(separator: " ")
            .joined(separator: " ")
    }

    /// ADDRESS SPELLINGS, deliberately generous.
    ///
    /// The address is a GATE, not a target: its whole job is to separate "this
    /// is for you" from "this is for the page". A homophone that fails to
    /// match costs the user their only spoken exit from the session — they say
    /// "Mary, stop writing", it lands in the manuscript as prose, they say it
    /// again, and it lands again. Recognising a spelling Whisper invented costs
    /// nothing by comparison, because the phrase still has to be a control
    /// phrase and nothing else.
    static let dictationAddressWords: Set<String> = [
        "mary", "bonny", "bonni", "bonne", "hey", "ok", "okay",
    ]

    private static let dictationStopPhrases: Set<String> = [
        "stop writing", "stop dictating", "stop dictation",
        "thats it", "that is it", "were done", "we are done", "im done", "i am done",
        "end dictation", "stop taking this down",
    ]

    private static let dictationScratchPhrases: Set<String> = [
        "scratch that", "strike that", "delete that", "take that back",
    ]

    private static let dictationStructuralPhrases: [String: DictationControl] = [
        "new paragraph": .newParagraph,
        "new line": .newLine,
        "next paragraph": .newParagraph,
    ]

    /// WHAT THIS UTTERANCE MEANS INSIDE A SESSION, or nil for prose.
    ///
    /// RULE 1 — WHOLE AND EXACT. A control phrase that merely APPEARS in a
    /// longer utterance is prose. "Stop writing to her that night" is a
    /// sentence in a novel, and this rule alone removes most of the risk.
    ///
    /// RULE 2 — DESTRUCTIVE CONTROLS ARE ADDRESSED. Closing a session or
    /// deleting a span costs real work, so the utterance must consist of
    /// NOTHING BUT an address and a control phrase. `"Scratch that," she said`
    /// does not, so it is typed. The address may lead or trail: Whisper returns
    /// "Mary stop writing" and "stop writing Mary" from the same person on
    /// different days, and the rule is about what the utterance CONTAINS, not
    /// about word order.
    ///
    /// RULE 3 — STRUCTURAL CONTROLS MAY BE BARE. "new paragraph" is the
    /// established dictation idiom, and misfiring costs one break that "Mary,
    /// scratch that" undoes. Two words of prose lost to a break is a fair trade
    /// for not making a novelist say "Mary" every paragraph.
    static func dictationControl(in text: String) -> DictationControl? {
        let normalized = normalizedUtterance(text)
        guard !normalized.isEmpty else { return nil }
        if let structural = dictationStructuralPhrases[normalized] { return structural }
        guard let stripped = addressStrippedControl(normalized) else { return nil }
        if let structural = dictationStructuralPhrases[stripped] { return structural }
        if dictationStopPhrases.contains(stripped) { return .stop }
        if dictationScratchPhrases.contains(stripped) { return .scratch }
        return nil
    }

    /// The utterance with its address words removed — but ONLY if what remains
    /// is the whole of the rest. Returns nil when the utterance carried no
    /// address at all, which is what makes rule 2 a gate rather than a hint.
    private static func addressStrippedControl(_ normalized: String) -> String? {
        var words = normalized.split(separator: " ").map(String.init)
        var strippedAny = false
        while let first = words.first, dictationAddressWords.contains(first) {
            words.removeFirst()
            strippedAny = true
        }
        while let last = words.last, dictationAddressWords.contains(last) {
            words.removeLast()
            strippedAny = true
        }
        guard strippedAny, !words.isEmpty else { return nil }
        return words.joined(separator: " ")
    }

    /// AN ADDRESSED UTTERANCE THAT IS NOT A CONTROL — the escape hatch.
    ///
    /// "Mary, what time is it" must not be typed into the manuscript, and it
    /// must not close the session either. It falls through to the ordinary turn
    /// loop for that one utterance. This is what lets the address prefix mean
    /// ONE consistent thing — *this is for you, not for the page* — instead of
    /// meaning it only for the four phrases we happened to list.
    static func isDictationEscape(_ text: String) -> Bool {
        let normalized = normalizedUtterance(text)
        guard !normalized.isEmpty else { return false }
        guard dictationControl(in: text) == nil else { return false }
        let words = normalized.split(separator: " ").map(String.init)
        guard let first = words.first else { return false }
        // A LEADING address only. "Mary" at the end of a dictated line is far
        // likelier to be a character's name being addressed in dialogue.
        guard dictationAddressWords.contains(first), words.count > 1 else { return false }
        // "ok" and "okay" open ordinary prose sentences constantly ("Okay, she
        // said"), so they alone are not an address — they only strip in
        // company, which `addressStrippedControl` handles for controls.
        return first == "mary" || first == "bonny"
            || first == "bonni" || first == "bonne"
            || (words.count > 2 && dictationAddressWords.contains(words[1]))
    }

    /// THE OPENER — the last utterance in a dictation session that is
    /// classified at all.
    static func dictationOpener(in text: String) -> Bool {
        var normalized = normalizedUtterance(text)
        // The same preamble peel the edit classifier does, so "okay Mary,
        // take this down" opens a session.
        var words = normalized.split(separator: " ").map(String.init)
        while let first = words.first, dictationAddressWords.contains(first) {
            words.removeFirst()
        }
        normalized = words.joined(separator: " ")
        let openers: Set<String> = [
            "take this down", "take dictation", "start writing", "start dictating",
            "write this down", "im going to dictate", "i am going to dictate",
            "let me dictate", "take down what i say",
        ]
        return openers.contains(normalized)
    }

    // MARK: - The turn halves

    /// Open a session, or refuse honestly. This is the LAST utterance that is
    /// classified at all until the session closes.
    func openDictationSession(
        userText: String,
        continuation: AsyncThrowingStream<BrainEvent, Error>.Continuation,
        epoch: UInt64
    ) async {
        let userTurn = BrainTurn(role: .user, text: userText)
        continuation.yield(.turnBegan(id: userTurn.id))
        appendHistory(userTurn, epoch: epoch)
        let result = await DictationSession.openSession(app: nil)
        let spoken: String
        if let held = result.held {
            spoken = "Listening — \(held.spokenPlace)."
            // ONE MARKER, NOT THE PROSE. History records that a session opened
            // and where; the sentences themselves never enter it.
            appendHistory(
                BrainTurn(role: .assistant, text: spoken), epoch: epoch)
        } else {
            spoken = result.refusal ?? "I couldn't start dictating."
            appendHistory(BrainTurn(role: .assistant, text: spoken), epoch: epoch)
        }
        continuation.yield(.token(spoken))
        continuation.yield(.completed(fullText: spoken))
    }

    /// Answer one utterance inside a held session.
    ///
    /// Returns false when the utterance is an ADDRESSED NON-CONTROL — the
    /// escape hatch — so the caller lets the ordinary turn loop have it with
    /// the session left intact.
    func runHeldDictationTurn(
        userText: String,
        continuation: AsyncThrowingStream<BrainEvent, Error>.Continuation,
        epoch: UInt64
    ) async -> Bool {
        let control = Self.dictationControl(in: userText)
        if control == nil, Self.isDictationEscape(userText) { return false }

        let userTurn = BrainTurn(role: .user, text: userText)
        continuation.yield(.turnBegan(id: userTurn.id))

        switch control {
        case .stop:
            let closed = DictationSession.shared.close()
            let words = closed?.wordsTyped ?? 0
            let spoken = words == 0
                ? "Stopped — nothing written."
                : "Done — \(SpokenPhrase.countWord(words)) \(words == 1 ? "word" : "words")."
            appendHistory(BrainTurn(role: .user, text: userText), epoch: epoch)
            appendHistory(BrainTurn(role: .assistant, text: spoken), epoch: epoch)
            continuation.yield(.token(spoken))
            continuation.yield(.completed(fullText: spoken))
            return true

        case .scratch:
            let result = await DictationSession.scratchLastSpan()
            let spoken: String
            switch result {
            case .typed: spoken = "Scratched."
            case .lostSurface(let reason): spoken = reason
            case .unavailable: spoken = "There's nothing to scratch."
            }
            continuation.yield(.token(spoken))
            continuation.yield(.completed(fullText: spoken))
            return true

        case .newParagraph, .newLine:
            let breakText = control == .newParagraph ? "\n\n" : "\n"
            _ = await typeDictatedSpan(breakText, continuation: continuation)
            return true

        case nil:
            _ = await typeDictatedSpan(userText, continuation: continuation)
            return true
        }
    }

    /// SILENT ON SUCCESS. TTS is driven by `.token`, so a dictated span yields
    /// none and completes empty — Mary types and says nothing, which is the
    /// only tolerable behaviour when the user is mid-sentence. Only a failure
    /// speaks, and a failure has already closed the session.
    private func typeDictatedSpan(
        _ text: String,
        continuation: AsyncThrowingStream<BrainEvent, Error>.Continuation
    ) async -> Bool {
        let result = await DictationSession.typeSpan(text)
        switch result {
        case .typed:
            continuation.yield(.completed(fullText: ""))
            return true
        case .lostSurface(let reason):
            continuation.yield(.token(reason))
            continuation.yield(.completed(fullText: reason))
            return false
        case .unavailable:
            let spoken = "I've stopped dictating."
            DictationSession.shared.close()
            continuation.yield(.token(spoken))
            continuation.yield(.completed(fullText: spoken))
            return false
        }
    }
}
