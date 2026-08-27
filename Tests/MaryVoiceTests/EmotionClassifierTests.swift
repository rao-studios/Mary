import Foundation
import Testing
@testable import MaryVoice

@Suite struct EmotionClassifierTests {

    @Test func questionsReadCurious() {
        #expect(EmotionClassifier.classify("What time does the launch start?") == .curious)
        #expect(EmotionClassifier.classify("Really?") == .curious)
    }

    @Test func exclaimedDelightReadsExcited() {
        #expect(EmotionClassifier.classify("This is amazing!") == .excited)
        #expect(EmotionClassifier.classify("What a fantastic result!") == .excited)
    }

    @Test func doubleExclamationReadsExcited() {
        #expect(EmotionClassifier.classify("We shipped it!!") == .excited)
    }

    @Test func angerKeywordsBeatSentiment() {
        #expect(EmotionClassifier.classify("I hate this!") == .angry)
        #expect(EmotionClassifier.classify("That is completely unacceptable.") == .angry)
    }

    @Test func sadnessCuesReadSad() {
        #expect(EmotionClassifier.classify("Unfortunately, the build failed again.") == .sad)
        #expect(EmotionClassifier.classify("I'm sorry for your loss, that is tragic.") == .sad)
    }

    @Test func plainStatementsReadNeutral() {
        #expect(EmotionClassifier.classify("The file is in the Documents folder.") == .neutral)
        #expect(EmotionClassifier.classify("It compiles in six seconds.") == .neutral)
    }

    @Test func positiveSentimentWithoutExclamationReadsHappy() {
        #expect(EmotionClassifier.classify(
            "That went really well and I enjoyed every part of it.") == .happy)
    }

    @Test func shortAcronymsDoNotShout() {
        #expect(EmotionClassifier.classify("OK, the AI model is ready.") == .neutral)
    }

    @Test func clampsToAllowedSet() {
        let limited: Set<MarieEmotion> = [.neutral, .sad]
        #expect(EmotionClassifier.classify("This is amazing!", allowed: limited) == .neutral)
        #expect(EmotionClassifier.classify("Unfortunately it broke.", allowed: limited) == .sad)
    }

    @Test func emptyTextReadsNeutral() {
        #expect(EmotionClassifier.classify("") == .neutral)
        #expect(EmotionClassifier.classify("   \n") == .neutral)
    }

    @Test func deterministic() {
        let text = "Wow, this is incredible! Can you believe it?"
        let first = EmotionClassifier.classify(text)
        for _ in 0..<10 {
            #expect(EmotionClassifier.classify(text) == first)
        }
    }
}

/// The shouting and question triggers, re-bounded. A single ALL-CAPS acronym
/// — "API", "JSON", daily vocabulary here — used to flip a whole chunk into
/// the excited voice, and a trailing "?" repainted every statement before it
/// as curious. Shouting is a claim about the sentence now; curiosity needs
/// the whole chunk to be a question.
@Suite struct EmotionTriggerBoundsTests {

    @Test func acronymsDoNotShout() {
        #expect(EmotionClassifier.classify("The API returns JSON.") == .neutral)
        #expect(EmotionClassifier.classify("Use the JSON API now.") == .neutral)
        #expect(EmotionClassifier.classify("The TTS engine is ready.") == .neutral)
    }

    @Test func genuineShoutingStillReadsExcited() {
        #expect(EmotionClassifier.classify("STOP DOING THAT") == .excited)
        #expect(EmotionClassifier.classify("WOW!") == .excited)
    }

    @Test func mixedStatementAndQuestionIsNotCurious() {
        #expect(EmotionClassifier.classify("It stopped twice. Should we look?") != .curious)
    }

    @Test func aPureQuestionStillReadsCurious() {
        #expect(EmotionClassifier.classify("Should we tighten the intro?") == .curious)
    }
}
