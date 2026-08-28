//
//  ToolCallTextInterceptorTests.swift
//  MaryBrainTests
//
//  The gate that keeps tool-call syntax out of spoken text. The streaming
//  half is driven the way engines drive it — chunk sequences into ingest,
//  then finish — including the live-bug shape: a name-prefixed call split
//  across chunks. The false-positive pins matter as much as the catches:
//  coding answers, literal JSON, and plain prose must stream untouched.
//

import Foundation
import Testing
@testable import MaryBrain
@testable import MaryPlugin
@testable import MaryAmbient

@Suite struct ToolCallTextInterceptorTests {

    private let roster: Set<String> = ["run_applescript", "run_shell", "probe", "now_playing"]

    private func drive(
        _ chunks: [String],
        roster: Set<String>? = nil
    ) -> (emitted: String, resolution: SkillCallTextInterceptor.Resolution) {
        var interceptor = SkillCallTextInterceptor(knownSkillNames: roster ?? self.roster)
        var emitted = ""
        for chunk in chunks {
            emitted += interceptor.ingest(chunk)
        }
        return (emitted, interceptor.finish())
    }

    private func calls(_ resolution: SkillCallTextInterceptor.Resolution) -> [ModelSkillInvocation] {
        if case .skillInvocations(let calls) = resolution { return calls }
        return []
    }

    private func speech(_ resolution: SkillCallTextInterceptor.Resolution) -> String? {
        if case .speech(let text) = resolution { return text }
        return nil
    }

    // MARK: - Catches

    /// THE live-bug shape: a name-prefixed call split across chunks. Nothing
    /// spoken; the call parses and RUNS.
    @Test func namePrefixedCallSplitAcrossChunksIsIntercepted() {
        let (emitted, resolution) = drive([
            "run_app", "lescript",
            #"{"name":"run_applescript","arguments":{"script":"tell app"}}"#,
        ])
        #expect(emitted.isEmpty)
        let parsed = calls(resolution)
        #expect(parsed.map(\.name) == ["run_applescript"])
        #expect(parsed.first?.argumentsJSON.contains("tell app") == true)
    }

    /// Args-only object under a name anchor adopts the anchor's name.
    @Test func argsOnlyObjectAdoptsAnchorName() {
        let (emitted, resolution) = drive([#"run_applescript{"script": "x"}"#])
        #expect(emitted.isEmpty)
        let parsed = calls(resolution)
        #expect(parsed.map(\.name) == ["run_applescript"])
        #expect(parsed.first?.argumentsJSON.contains("script") == true)
    }

    /// Prose before a call is spoken; the call is withheld and parsed.
    @Test func prosePrefixSpokenCallWithheld() {
        let (emitted, resolution) = drive([
            "I'll do it now. ",
            #"run_applescript{"script": "x"}"#,
        ])
        #expect(emitted == "I'll do it now. ")
        #expect(calls(resolution).map(\.name) == ["run_applescript"])
    }

    /// Mistral-parity trio: bare-brace head, fenced json head, native marker.
    @Test func parityTriggersStillIntercept() {
        // Bare {.
        let bare = drive([#"{"name": "probe", "arguments": {"a": "b"}}"#])
        #expect(bare.emitted.isEmpty)
        #expect(calls(bare.resolution).map(\.name) == ["probe"])
        // Fenced json.
        let fenced = drive(["```json\n", #"{"name": "probe", "arguments": {}}"#, "\n```"])
        #expect(fenced.emitted.isEmpty)
        #expect(calls(fenced.resolution).map(\.name) == ["probe"])
        // Native marker, multi-call array, trailing hallucination dropped.
        let native = drive([
            #"[TOOL_CALLS] [{"name": "probe", "arguments": {}}, {"name": "run_shell", "arguments": {"command": "ls"}}] and more chatter"#,
        ])
        #expect(native.emitted.isEmpty)
        #expect(calls(native.resolution).map(\.name) == ["probe", "run_shell"])
    }

    /// Mistral's own demanded tag format is finally recognized.
    @Test func toolCallTagIntercepted() {
        let (emitted, resolution) = drive([
            "<tool_call>", #"{"name": "probe", "arguments": {}}"#, "</tool_call>",
        ])
        #expect(emitted.isEmpty)
        #expect(calls(resolution).map(\.name) == ["probe"])
    }

    /// Truncated tool syntax (stream cut mid-call) is DROPPED — speaking
    /// the fragment would read raw JSON aloud.
    @Test func truncatedNameAnchoredCallIsDropped() {
        let (emitted, resolution) = drive([
            "run_applescript", #"{"script": "tell app"#,
        ])
        #expect(emitted.isEmpty)
        if case .dropped = resolution {} else {
            Issue.record("expected .dropped, got \(resolution)")
        }
    }

    /// Echoed internal tool-result label is stripped from flushed speech.
    @Test func echoedToolResultLabelStripped() {
        let (emitted, resolution) = drive(["[tool result — open_app]: done"])
        #expect(emitted.isEmpty)
        #expect(speech(resolution) == "done")
    }

    // MARK: - False positives

    /// A literal JSON answer whose "name" is not a tool stays speech.
    @Test func literalJSONWithNonToolNameStaysSpeech() {
        let (emitted, resolution) = drive([#"{"name": "Ritesh"}"#])
        #expect(emitted.isEmpty)
        #expect(speech(resolution)?.contains("Ritesh") == true)
    }

    /// A coding answer in a ```swift fence resumes streaming immediately
    /// (fence early-out) instead of being withheld to end of round.
    @Test func swiftFenceStreamsThrough() {
        let chunks = ["```swift\n", "let answer = compute()\n", "```"]
        let (emitted, resolution) = drive(chunks)
        #expect(emitted == chunks.joined())
        if case .nothing = resolution {} else {
            Issue.record("expected .nothing, got \(resolution)")
        }
    }

    /// Mid-prose bare braces never suppress — only name-anchored calls do.
    @Test func midProseBareBraceNeverSuppresses() {
        let chunks = ["The config is ", #"{"name": "probe", "arguments": {}}"#, " okay?"]
        let (emitted, resolution) = drive(chunks)
        #expect(emitted == chunks.joined())
        if case .nothing = resolution {} else {
            Issue.record("expected .nothing, got \(resolution)")
        }
    }

    /// Plain prose streams through unchanged, chunk boundaries and all.
    @Test func plainProseStreamsVerbatim() {
        let chunks = ["Sure — ", "the timer is ", "set for 3pm."]
        let (emitted, resolution) = drive(chunks)
        var tail = ""
        if case .speech(let s) = resolution { tail = s }
        #expect(emitted + tail == chunks.joined())
    }

    /// With an empty roster the identifier trigger and mid-prose scan are
    /// inert — only format-anchored triggers fire (Mistral-shim parity).
    @Test func emptyRosterKeepsIdentifierTriggerInert() {
        let text = #"run_applescript{"script": "x"}"#
        let (emitted, resolution) = drive([text], roster: [])
        var tail = ""
        if case .speech(let s) = resolution { tail = s }
        #expect(emitted + tail == text)
    }

    // MARK: - stripToolCallSyntax

    @Test func stripRemovesMidProseCallKeepsProse() {
        let stripped = SkillCallTextInterceptor.stripToolCallSyntax(
            from: #"Sure. run_applescript{"script": "x"} Done."#,
            knownSkillNames: roster)
        #expect(stripped == "Sure. Done.")
    }

    @Test func stripIsNoOpOnCleanContent() {
        let clean = [
            "Just a plain sentence about run_applescript usage.",
            "Here:\n```swift\nlet a = [1]\nstruct T {}\n```",
            #"{"name": "Ritesh", "arguments": {}}"#,   // non-tool name, roster present
            "An unbalanced { brace stays.",
        ]
        for text in clean {
            #expect(SkillCallTextInterceptor.stripToolCallSyntax(
                from: text, knownSkillNames: roster) == text, "\(text)")
        }
    }

    @Test func stripRemovesNativeBlobAndTag() {
        let native = SkillCallTextInterceptor.stripToolCallSyntax(
            from: #"[TOOL_CALLS] [{"name": "probe", "arguments": {}}] then chatter"#,
            knownSkillNames: roster)
        #expect(native == "then chatter")
        let tagged = SkillCallTextInterceptor.stripToolCallSyntax(
            from: #"Okay. <tool_call>{"name": "probe", "arguments": {}}</tool_call> Sent."#,
            knownSkillNames: roster)
        #expect(tagged == "Okay. Sent.")
    }

    @Test func stripRemovesFencedToolObjectWithFence() {
        let stripped = SkillCallTextInterceptor.stripToolCallSyntax(
            from: "Before.\n```json\n{\"name\": \"probe\", \"arguments\": {}}\n```\nAfter.",
            knownSkillNames: roster)
        #expect(!stripped.contains("probe"))
        #expect(!stripped.contains("```"))
        #expect(stripped.contains("Before."))
        #expect(stripped.contains("After."))
    }

    @Test func stripTruncatedCallRemovesToEnd() {
        let stripped = SkillCallTextInterceptor.stripToolCallSyntax(
            from: #"On it. run_applescript{"script": "tell"#,
            knownSkillNames: roster)
        #expect(stripped == "On it.")
    }

    /// Without a roster, bare objects still strip when tool-call-shaped
    /// (name + arguments/parameters).
    @Test func stripEmptyRosterUsesShapeHeuristic() {
        let stripped = SkillCallTextInterceptor.stripToolCallSyntax(
            from: #"Done. {"name": "anything", "arguments": {"x": 1}}"#)
        #expect(stripped == "Done.")
        let kept = SkillCallTextInterceptor.stripToolCallSyntax(
            from: #"Done. {"name": "anything"}"#)
        #expect(kept == #"Done. {"name": "anything"}"#)
    }
}
