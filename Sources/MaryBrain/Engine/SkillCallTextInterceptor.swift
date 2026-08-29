//
//  SkillCallTextInterceptor.swift
//  MaryBrain
//
//  The shared gate that keeps tool-call syntax out of spoken text. Models
//  under pressure narrate calls as prose — Mistral's native [TOOL_CALLS]
//  wire format, fenced/bare JSON, the <tool_call> tag, or a name-prefixed
//  blob like `run_applescript{"script": …}` (the shape that leaked into a
//  live reply). One instance lives per stream round: text is withheld while
//  it could still be a call, parsed into ModelSkillInvocations at end of round
//  (so the action actually RUNS), and flushed as speech when it turns out
//  to be prose after all. `stripToolCallSyntax` is the pure whole-string
//  belt-and-braces the brain runs over captured prose and history writes.
//

import Foundation

struct SkillCallTextInterceptor {

    enum Resolution {
        case nothing
        /// The withheld text was prose after all (echo label stripped).
        case speech(String)
        case skillInvocations([ModelSkillInvocation])
        /// Truncated tool syntax — never speakable, never runnable.
        case dropped
    }

    private enum Anchor {
        case bracketHead            // "[" — [TOOL_CALLS] or an echoed label
        case braceHead              // "{"
        case fenceHead              // ```
        case tagHead                // <tool_call>
        case namePrefixed(String)   // run_applescript{…}
    }

    private enum Phase {
        case undecided
        case suppressing(Anchor)
        case passthrough
    }

    /// Lowercased roster. Empty roster keeps the identifier trigger and the
    /// mid-prose scan inert — only the format-anchored triggers fire.
    private let knownSkillNames: Set<String>
    private var phase: Phase = .undecided
    private var pending = ""
    /// Passthrough hold: a trailing token that may still grow into a
    /// known-name + "{" call start.
    private var heldTail = ""

    init(knownSkillNames: Set<String>) {
        self.knownSkillNames = Set(knownSkillNames.map { $0.lowercased() })
    }

    /// Feed one streamed chunk; returns the text that is safe to emit now
    /// ("" while withholding).
    mutating func ingest(_ chunk: String) -> String {
        switch phase {
        case .passthrough:
            return scanProse(chunk)
        case .suppressing(let anchor):
            pending += chunk
            if case .fenceHead = anchor { return checkFenceEarlyOut() }
            return ""
        case .undecided:
            pending += chunk
            return evaluateUndecided()
        }
    }

    /// End of round: resolve whatever is still held.
    mutating func finish() -> Resolution {
        defer { pending = ""; heldTail = ""; phase = .undecided }
        switch phase {
        case .passthrough:
            return heldTail.isEmpty ? .nothing : .speech(heldTail)
        case .undecided:
            // Never classified — a hold that stayed a prefix. Prose.
            return pending.isEmpty ? .nothing : .speech(pending)
        case .suppressing(let anchor):
            let native = Self.parseNativeToolCalls(from: pending)
            var fallbackName: String?
            if case .namePrefixed(let name) = anchor { fallbackName = name }
            let parsed = native.isEmpty
                ? Self.parseLooseToolCalls(
                    from: pending, knownSkillNames: knownSkillNames, fallbackName: fallbackName)
                : native
            if !parsed.isEmpty { return .skillInvocations(parsed) }
            switch anchor {
            case .namePrefixed, .tagHead:
                // It unmistakably TRIED to be a call and didn't parse —
                // speaking the fragment would read raw JSON aloud.
                return .dropped
            case .bracketHead, .braceHead, .fenceHead:
                let cleaned = Self.strippingToolResultEcho(pending)
                return cleaned.isEmpty ? .nothing : .speech(cleaned)
            }
        }
    }

    // MARK: - Undecided head classification

    private enum HeadClass {
        case suppress(Anchor)
        case hold
        case flush
    }

    private mutating func evaluateUndecided() -> String {
        let head = pending.drop(while: \.isWhitespace)
        guard !head.isEmpty else { return "" }
        switch classifyHead(head) {
        case .suppress(let anchor):
            phase = .suppressing(anchor)
            if case .fenceHead = anchor { return checkFenceEarlyOut() }
            return ""
        case .hold:
            return ""
        case .flush:
            let out = pending
            pending = ""
            phase = .passthrough
            // The flushed text may itself contain a mid-prose call
            // ("Sure. run_applescript{…}" arriving as one chunk).
            return scanProse(out)
        }
    }

    private func classifyHead(_ head: Substring) -> HeadClass {
        guard let first = head.first else { return .hold }
        if first == "[" { return .suppress(.bracketHead) }
        if first == "{" { return .suppress(.braceHead) }
        if first == "`" {
            if head.hasPrefix("```") { return .suppress(.fenceHead) }
            return "```".hasPrefix(head) ? .hold : .flush
        }
        if first == "<" {
            let tag = "<tool_call>"
            if head.hasPrefix(tag) { return .suppress(.tagHead) }
            return tag.hasPrefix(String(head.prefix(tag.count))) ? .hold : .flush
        }
        if first.isLetter || first == "_" {
            let token = head.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            let lowered = token.lowercased()
            let rest = head[token.endIndex...]
            if rest.isEmpty {
                // Token may still be growing into a known name.
                return knownSkillNames.contains { $0.hasPrefix(lowered) } ? .hold : .flush
            }
            guard knownSkillNames.contains(lowered) else { return .flush }
            let afterSpaces = rest.drop(while: { $0 == " " })
            if afterSpaces.isEmpty { return .hold }   // "{" may be next
            return afterSpaces.first == "{"
                ? .suppress(.namePrefixed(lowered))
                : .flush
        }
        return .flush
    }

    /// Fence info strings that plausibly label a tool call rather than a
    /// code sample — checked case-insensitively, alongside the empty string.
    ///
    /// THE FAILURE THIS FIXES, live: Xcode genuinely frontmost,
    /// `read_buffer` genuinely offered, and the on-device model reached for
    /// it — but wrapped the call as ` ```tool_call\n{"name": "read_buffer"}\n``` `
    /// rather than the `<tool_call>` tag the prompt names or a bare/`json`
    /// fence this gate already knew. `json` was the only accepted label, so
    /// the whole block fell through to `flushAllToProse()` and the raw fence
    /// — literally "```tool_call" — was SPOKEN, and the call never ran. The
    /// call was real; only the label was unrecognized.
    static let toolCallFenceInfoStrings: Set<String> = ["json", "tool_call", "tool_calls"]

    /// While suppressing a fence: once the opening line is complete, keep
    /// suppressing only when it plausibly wraps a tool call (empty/`json`/
    /// `tool_call`/`tool_calls` info string, first content char "{" or "[").
    /// A ```swift coding answer resumes streaming immediately instead of
    /// being withheld to end of round.
    private mutating func checkFenceEarlyOut() -> String {
        let head = pending.drop(while: \.isWhitespace)
        guard head.count >= 3 else { return "" }
        guard let newline = head.firstIndex(of: "\n") else { return "" }
        let infoStart = head.index(head.startIndex, offsetBy: 3)
        guard infoStart <= newline else { return "" }
        let info = head[infoStart..<newline].trimmingCharacters(in: .whitespaces)
        if !info.isEmpty, !Self.toolCallFenceInfoStrings.contains(info.lowercased()) {
            return flushAllToProse()
        }
        let content = head[head.index(after: newline)...].drop(while: \.isWhitespace)
        guard let firstContent = content.first else { return "" }
        return (firstContent == "{" || firstContent == "[") ? "" : flushAllToProse()
    }

    private mutating func flushAllToProse() -> String {
        let out = pending
        pending = ""
        phase = .passthrough
        return scanProse(out)
    }

    // MARK: - Passthrough (prose has started)

    /// Prose is flowing, but a call can still appear mid-reply ("I'll do it
    /// now. run_applescript{…}") — and legacy mode streams tokens LIVE, so
    /// history stripping can't unspeak it. Scan for word-boundary known-name
    /// + optional spaces + "{"; bare braces and fences never trigger here
    /// (the false-positive guard for coding answers and literal JSON).
    private mutating func scanProse(_ incoming: String) -> String {
        let buffer = heldTail + incoming
        heldTail = ""
        guard !knownSkillNames.isEmpty, !buffer.isEmpty else { return buffer }

        if let hit = Self.firstToolCallStart(in: buffer, names: knownSkillNames) {
            pending = String(buffer[hit.start...])
            phase = .suppressing(.namePrefixed(hit.name))
            return String(buffer[..<hit.start])
        }
        if let holdStart = Self.trailingCandidateStart(in: buffer, names: knownSkillNames) {
            let tail = String(buffer[holdStart...])
            // Safety cap: a pathological hold flows through rather than pool.
            if tail.count <= 80 {
                heldTail = tail
                return String(buffer[..<holdStart])
            }
        }
        return buffer
    }

    /// Earliest word-boundary known tool name followed by optional spaces
    /// and "{".
    static func firstToolCallStart(
        in text: String, names: Set<String>
    ) -> (start: String.Index, name: String)? {
        var index = text.startIndex
        var previousIsIdentifier = false
        while index < text.endIndex {
            let ch = text[index]
            let isIdentifierStart = ch.isLetter || ch == "_"
            if isIdentifierStart, !previousIsIdentifier {
                let tokenStart = index
                var j = index
                while j < text.endIndex,
                      text[j].isLetter || text[j].isNumber || text[j] == "_" {
                    j = text.index(after: j)
                }
                let token = String(text[tokenStart..<j]).lowercased()
                if names.contains(token) {
                    var k = j
                    while k < text.endIndex, text[k] == " " { k = text.index(after: k) }
                    if k < text.endIndex, text[k] == "{" {
                        return (tokenStart, token)
                    }
                }
                previousIsIdentifier = true
                index = j
                continue
            }
            previousIsIdentifier = ch.isLetter || ch.isNumber || ch == "_"
            index = text.index(after: index)
        }
        return nil
    }

    /// Start of a trailing token that may still grow into a call start: a
    /// partial known-name prefix, or a complete known name followed only by
    /// spaces (its "{" may be in the next chunk).
    static func trailingCandidateStart(
        in text: String, names: Set<String>
    ) -> String.Index? {
        var index = text.endIndex
        var sawSpace = false
        while index > text.startIndex {
            let prev = text.index(before: index)
            guard text[prev] == " " else { break }
            sawSpace = true
            index = prev
        }
        let tokenEnd = index
        while index > text.startIndex {
            let prev = text.index(before: index)
            let ch = text[prev]
            guard ch.isLetter || ch.isNumber || ch == "_" else { break }
            index = prev
        }
        guard index < tokenEnd else { return nil }
        let token = String(text[index..<tokenEnd]).lowercased()
        if sawSpace {
            return names.contains(token) ? index : nil
        }
        return names.contains(where: { $0.hasPrefix(token) }) ? index : nil
    }

    // MARK: - Parsers (moved from MaryLocalEngine)

    /// Weak models sometimes parrot the "[tool result — name]:" label the
    /// engine uses internally for tool turns. Strip it from spoken replies.
    static func strippingToolResultEcho(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("[tool result") else { return trimmed }
        guard let close = trimmed.range(of: "]:") else { return trimmed }
        return String(trimmed[close.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    /// Parse a fenced, bare, tagged, or name-prefixed JSON tool call. A
    /// parsed "name" counts only when it's in the roster (an empty roster
    /// accepts any — Mistral-shim parity); an args-only object under a
    /// name-prefixed anchor adopts the anchor's name.
    static func parseLooseToolCalls(
        from text: String,
        knownSkillNames: Set<String> = [],
        fallbackName: String? = nil
    ) -> [ModelSkillInvocation] {
        guard let open = text.firstIndex(of: "{") else { return [] }
        guard let end = matchingClose(
            in: text[...], from: open, openChar: "{", closeChar: "}") else { return [] }

        let json = String(text[open...end])
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        let names = Set(knownSkillNames.map { $0.lowercased() })
        let declared = (object["name"] as? String)?.lowercased()

        let name: String
        var arguments: [String: Any]
        if let declared, !declared.isEmpty, names.isEmpty || names.contains(declared) {
            name = declared
            arguments = (object["arguments"] as? [String: Any])
                ?? (object["parameters"] as? [String: Any])
                ?? object.filter { $0.key != "name" }
        } else if let fallbackName {
            // run_applescript{"script": …} — no "name" key (or a literal
            // one); the anchor named the tool.
            name = fallbackName
            arguments = (object["arguments"] as? [String: Any])
                ?? (object["parameters"] as? [String: Any])
                ?? object
        } else {
            // {"name": "Ritesh"} in a literal-JSON answer is NOT a call.
            return []
        }
        let argumentsJSON: String
        if let argsData = try? JSONSerialization.data(withJSONObject: arguments),
           let argsString = String(data: argsData, encoding: .utf8) {
            argumentsJSON = argsString
        } else {
            argumentsJSON = "{}"
        }
        return [ModelSkillInvocation(
            id: "local-\(UUID().uuidString.prefix(8))",
            name: name,
            argumentsJSON: argumentsJSON
        )]
    }

    /// Parse Mistral's native `[TOOL_CALLS] [{"name": ..., "arguments": {...}}, …]`.
    /// Anything after the array (post-call hallucination) is dropped.
    static func parseNativeToolCalls(from text: String) -> [ModelSkillInvocation] {
        guard let markerRange = text.range(of: "[TOOL_CALLS]") else { return [] }
        let tail = text[markerRange.upperBound...]
        guard let open = tail.firstIndex(of: "[") else { return [] }
        guard let end = matchingClose(
            in: tail, from: open, openChar: "[", closeChar: "]") else { return [] }

        let json = String(tail[open...end])
        guard let data = json.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return items.compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            let arguments = item["arguments"] as? [String: Any] ?? [:]
            let argumentsJSON: String
            if let argsData = try? JSONSerialization.data(withJSONObject: arguments),
               let argsString = String(data: argsData, encoding: .utf8) {
                argumentsJSON = argsString
            } else {
                argumentsJSON = "{}"
            }
            return ModelSkillInvocation(
                id: "local-\(UUID().uuidString.prefix(8))",
                name: name,
                argumentsJSON: argumentsJSON
            )
        }
    }

    /// String-aware bracket matching shared by every parser: index of the
    /// close that balances the open bracket at `from`.
    static func matchingClose(
        in text: Substring,
        from open: Substring.Index,
        openChar: Character,
        closeChar: Character
    ) -> Substring.Index? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = open
        while index < text.endIndex {
            let ch = text[index]
            if escaped {
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "\"" {
                inString.toggle()
            } else if !inString {
                if ch == openChar { depth += 1 }
                if ch == closeChar {
                    depth -= 1
                    if depth == 0 { return index }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    // MARK: - Whole-string stripping (the brain's belt-and-braces)

    /// Remove tool-call syntax from finished prose: [TOOL_CALLS] blobs,
    /// <tool_call> spans, known-name-prefixed objects, bare/fenced objects
    /// that are tool-call-shaped. Truncated call syntax strips to end of
    /// string (never speakable). Clean prose comes back UNCHANGED —
    /// unbalanced braces and non-tool fences are strictly untouched.
    static func stripToolCallSyntax(
        from text: String, knownSkillNames: Set<String> = []
    ) -> String {
        var result = text
        var changed = false
        let names = Set(knownSkillNames.map { $0.lowercased() })

        // [TOOL_CALLS] + balanced array (or truncated → to end).
        while let markerRange = result.range(of: "[TOOL_CALLS]") {
            changed = true
            let tail = result[markerRange.upperBound...]
            if let open = tail.firstIndex(of: "["),
               let close = matchingClose(in: tail, from: open, openChar: "[", closeChar: "]") {
                removeSplice(&result, markerRange.lowerBound..<result.index(after: close))
            } else {
                result.removeSubrange(markerRange.lowerBound..<result.endIndex)
            }
        }

        // <tool_call>…</tool_call> spans (or truncated → to end).
        while let openTag = result.range(of: "<tool_call>") {
            changed = true
            if let closeTag = result.range(
                of: "</tool_call>", range: openTag.upperBound..<result.endIndex) {
                removeSplice(&result, openTag.lowerBound..<closeTag.upperBound)
            } else {
                result.removeSubrange(openTag.lowerBound..<result.endIndex)
            }
        }

        // knownName + optional spaces + {…}.
        while let hit = firstToolCallStart(in: result, names: names) {
            changed = true
            let braceSearch = result[hit.start...]
            guard let open = braceSearch.firstIndex(of: "{") else { break }
            if let close = matchingClose(
                in: result[...], from: open, openChar: "{", closeChar: "}") {
                removeSplice(&result, hit.start..<result.index(after: close))
            } else {
                result.removeSubrange(hit.start..<result.endIndex)
            }
        }

        // Bare or fenced objects that are tool-call-shaped.
        var scan = result.startIndex
        while let open = result[scan...].firstIndex(of: "{") {
            guard let close = matchingClose(
                in: result[...], from: open, openChar: "{", closeChar: "}") else { break }
            let json = String(result[open...close])
            if isToolCallShaped(json, names: names) {
                changed = true
                let range = expandToFence(in: result, objectRange: open..<result.index(after: close))
                removeSplice(&result, range)
                // Indices are invalid after mutation — rescan from the top
                // (each removal shrinks the string, so this terminates).
                scan = result.startIndex
            } else {
                scan = result.index(after: close)
            }
        }

        guard changed else { return text }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isToolCallShaped(_ json: String, names: Set<String>) -> Bool {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["name"] as? String, !name.isEmpty else {
            return false
        }
        if names.isEmpty {
            return object["arguments"] != nil || object["parameters"] != nil
        }
        return names.contains(name.lowercased())
    }

    /// If the object is the sole content of a ``` fence, take the fence too.
    private static func expandToFence(
        in text: String, objectRange: Range<String.Index>
    ) -> Range<String.Index> {
        // Backwards: skip whitespace, then the preceding line must be
        // exactly ``` or ```json.
        var beforeEnd = objectRange.lowerBound
        while beforeEnd > text.startIndex,
              text[text.index(before: beforeEnd)].isWhitespace {
            beforeEnd = text.index(before: beforeEnd)
        }
        guard beforeEnd > text.startIndex else { return objectRange }
        var lineStart = beforeEnd
        while lineStart > text.startIndex,
              text[text.index(before: lineStart)] != "\n" {
            lineStart = text.index(before: lineStart)
        }
        let fenceLine = text[lineStart..<beforeEnd].trimmingCharacters(in: .whitespaces)
        guard fenceLine == "```" || fenceLine.lowercased() == "```json" else { return objectRange }
        // Forwards: skip whitespace, then a closing ```.
        var afterStart = objectRange.upperBound
        while afterStart < text.endIndex, text[afterStart].isWhitespace {
            afterStart = text.index(after: afterStart)
        }
        guard text[afterStart...].hasPrefix("```") else { return objectRange }
        let closeEnd = text.index(afterStart, offsetBy: 3)
        return lineStart..<closeEnd
    }

    /// Remove a range and swallow the immediately following run of spaces
    /// when the removal would otherwise leave a doubled gap.
    private static func removeSplice(_ text: inout String, _ range: Range<String.Index>) {
        var upper = range.upperBound
        let precededBySpace = range.lowerBound == text.startIndex
            || text[text.index(before: range.lowerBound)] == " "
            || text[text.index(before: range.lowerBound)] == "\n"
        if precededBySpace {
            while upper < text.endIndex, text[upper] == " " {
                upper = text.index(after: upper)
            }
        }
        text.removeSubrange(range.lowerBound..<upper)
    }
}
