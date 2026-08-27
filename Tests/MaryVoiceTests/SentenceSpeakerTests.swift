import Foundation
import Testing
@testable import MaryVoice

/// The stream speaker's sentence chunking + sanitization, exercised through
/// its event tap with a real (unloaded) engine — synthesis is never reached
/// because we only inspect chunk batching decisions via chunkQueued events.
@Suite struct SentenceSpeakerTests {

    private func makeSpeaker(sentencesPerChunk: Int = 2, maxWords: Int = 30) -> KokoroStreamSpeaker {
        KokoroStreamSpeaker(
            engine: KokoroEngine(),
            sentencesPerChunk: sentencesPerChunk,
            maxWordsPerChunk: maxWords
        )
    }

    private func queuedChunks(
        _ speaker: KokoroStreamSpeaker,
        feed: @escaping (KokoroStreamSpeaker) async -> Void
    ) async -> [String] {
        let events = await speaker.events()
        let collector = Task { () -> [String] in
            var collected: [String] = []
            for await event in events {
                if case .chunkQueued(let text) = event { collected.append(text) }
            }
            return collected
        }
        await feed(speaker)
        try? await Task.sleep(nanoseconds: 150_000_000)
        collector.cancel()  // ends the stream iteration
        let chunks = await collector.value
        await speaker.hardStop()
        return chunks
    }

    @Test func batchesTwoCompleteSentences() async {
        let speaker = makeSpeaker()
        let chunks = await queuedChunks(speaker) { speaker in
            // Three sentences; the third proves the first two are complete.
            await speaker.feed("One is here. Two is here. Three begins")
        }
        #expect(chunks == ["One is here. Two is here."])
    }

    @Test func incompleteTrailingSentenceStaysBuffered() async {
        let speaker = makeSpeaker()
        let chunks = await queuedChunks(speaker) { speaker in
            await speaker.feed("This sentence never quite ends")
        }
        #expect(chunks.isEmpty)
    }

    @Test func markdownIsSanitized() async {
        let speaker = makeSpeaker(sentencesPerChunk: 1)
        let chunks = await queuedChunks(speaker) { speaker in
            await speaker.feed("**Bold** and `code` live here. Next one starts")
        }
        #expect(chunks.count == 1)
        #expect(chunks[0].contains("Bold"))
        #expect(!chunks[0].contains("*"))
        #expect(!chunks[0].contains("`"))
    }

    @Test func wordCapFlushesEarly() async {
        let speaker = makeSpeaker(sentencesPerChunk: 5, maxWords: 8)
        // NLTokenizer only splits at capitalized sentence starts.
        let long = "One two three four five six seven eight nine ten."
        let chunks = await queuedChunks(speaker) { speaker in
            await speaker.feed("Short one here. \(long) Tail begins")
        }
        // The long sentence would blow the 8-word budget, so the short one
        // flushes alone; the long one stays batched for flush().
        #expect(chunks == ["Short one here."])
    }
}
