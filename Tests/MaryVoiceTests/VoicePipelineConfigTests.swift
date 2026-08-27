import Testing
@testable import MaryVoice

@Suite struct VoicePipelineConfigTests {
    @Test func defaultsAreConversational() {
        let config = VoicePipelineConfig()
        #expect(config.sttBackend == .apple)
        #expect(config.voice == "af_heart")
        #expect(config.vad.hangoverMs == 850)
        #expect(config.vad.speechStartRMS < config.vad.speechStartRMS * config.vad.bargeInRMSBoost)
    }
}
