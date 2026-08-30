import Foundation
import Testing
@testable import MaryPlugin
@testable import MaryBrain
@testable import MaryAmbient

@Suite struct MistralNativeToolCallTests {

    @Test func parsesSingleCall() {
        let calls = MaryLocalEngine.parseNativeToolCalls(
            from: #"[TOOL_CALLS] [{"name": "speak_time", "arguments": {}}]"#)
        #expect(calls.count == 1)
        #expect(calls[0].name == "speak_time")
    }

    @Test func dropsTrailingHallucination() {
        let calls = MaryLocalEngine.parseNativeToolCalls(
            from: #"[TOOL_CALLS] [{"name": "open_project", "arguments": {"project": "mary"}}] The time is [current_time]."#)
        #expect(calls.count == 1)
        #expect(calls[0].argumentsJSON.contains("mary"))
    }

    @Test func bracketMatchingSurvivesStringsWithBrackets() {
        let calls = MaryLocalEngine.parseNativeToolCalls(
            from: #"[TOOL_CALLS] [{"name": "open_app", "arguments": {"app_name": "we[ird] app"}}]"#)
        #expect(calls.count == 1)
        #expect(calls[0].argumentsJSON.contains("we[ird] app"))
    }

    @Test func malformedReturnsEmpty() {
        #expect(MaryLocalEngine.parseNativeToolCalls(from: "[TOOL_CALLS] not json").isEmpty)
        #expect(MaryLocalEngine.parseNativeToolCalls(from: "no marker at all").isEmpty)
    }
}
