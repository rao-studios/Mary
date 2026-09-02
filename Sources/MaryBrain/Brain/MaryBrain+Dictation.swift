//
//  MaryBrain+Dictation.swift
//  MaryBrain
//
//  WHAT: Held-dictation mode — its own small grammar, and the turn halves.
//  IN:   runTurnBody
//  OUT:  write-prose vs speak-to-Mary
//  PIN:  UNWIRED IN MARY. `DictationRunner.installHooks` is a lazy `static let`
//        that nothing references, so the open/type/scratch hooks never install
//        and `DictationSession.openSession` always refuses with "Typing isn't
//        available in this build." `isHeld()` therefore never returns true and
//        `runHeldDictationTurn` is unreachable. Ported from the reference
//        implementation; either wire it (`_ = DictationRunner.installHooks`)
//        or delete the mode — do not grow it meanwhile.
//        MODE-LOCAL GRAMMAR: these phrases name a writing mode, so they are a
//        lane vocabulary the writing corpus can own, not tier protocol.
//
import MaryAmbient
import MaryPlugin
import MaryVoice
import Foundation

extension MaryBrain {

    // MARK: - The address gate

    /// ADDRESS SPELLINGS, deliberately generous.
    /// The address is a GATE, not a target: its whole job is to separate "this
    /// is for you" from "this is for the page".
    static let dictationAddressWords: Set<String> = ["mary", "hey", "ok", "okay"]

    /// IS THIS UTTERANCE FOR MARY, rather than for the page?
    /// THE WHOLE OF THE MODE'S GRAMMAR, and it is POSITIONAL — a rule about
    /// where her name sits, not a list of things one may say. The controls
    /// themselves (stop, scratch, new paragraph) are Skills the writing package
    /// declares, so an addressed utterance falls through to ordinary routing
    /// and finds them in the roster like any other Skill.
    static func isDictationAddressed(_ text: String) -> Bool {
        let normalized = DeterministicTier.normalized(text)
        guard !normalized.isEmpty else { return false }
        let words = normalized.split(separator: " ").map(String.init)
        guard let first = words.first else { return false }
        // A LEADING address only. "Mary" at the end of a dictated line is far
        // likelier to be a character's name being addressed in dialogue.
        // KNOWN LIMIT: the leading case stays ambiguous — "Mary stopped writing
        // at midnight" reads as addressed and goes to routing rather than onto
        // the page. Settling it needs the comma the recognizer dropped.
        guard dictationAddressWords.contains(first), words.count > 1 else { return false }
        // "ok" and "okay" open ordinary prose sentences constantly ("Okay, she
        // said"), so they alone are not an address — they only count in company.
        return first == "mary"
            || (words.count > 2 && dictationAddressWords.contains(words[1]))
    }

    // MARK: - The turn halves

    /// Answer one utterance inside a held session.
    /// Returns false when the utterance is ADDRESSED, which hands it back to
    /// ordinary routing — that is both the escape hatch ("Mary, what time is
    /// it") and the control channel, since stop/scratch/break are Skills the
    /// writing package declares and the roster already offers.
    func runHeldDictationTurn(
        userText: String,
        continuation: AsyncThrowingStream<BrainEvent, Error>.Continuation,
        epoch: UInt64
    ) async -> Bool {
        guard !Self.isDictationAddressed(userText) else { return false }
        let userTurn = BrainTurn(role: .user, text: userText)
        continuation.yield(.turnBegan(id: userTurn.id))
        _ = await typeDictatedSpan(userText, continuation: continuation)
        return true
    }

    /// SILENT ON SUCCESS. TTS is driven by `.token`, so a dictated span yields none and completes empty
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
