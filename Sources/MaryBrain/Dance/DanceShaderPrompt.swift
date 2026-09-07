//
//  DanceShaderPrompt.swift
//  MaryBrain
//
//  WHAT: The prompt a shader is composed with, and the strict parse of the
//        answer. No engine — composition runs through Sewn's /v1/complete.
//  IN:   SewnShaderComposer
//  OUT:  DanceComposition (a feeling line and the shader, fences and all)
//  PIN:  Tolerant on the way in, strict on the way out: the feeling is read
//        off a FEELING: line or the first prose line; the shader is whatever
//        fence or bare source follows, and `GLSLFragment.admit` judges it.
//

import Foundation
import MaryPlugin

public enum DanceShaderPrompt {

    public static let maximumFeelingLength = 160

    // MARK: - Prompt

    public static let systemPrompt = """
        You are Mary, composing a fragment shader that paints a feeling. Answer in \
        exactly this shape and nothing else:

        FEELING: <one spoken sentence, under twenty words, in the first person>
        ```glsl
        <the shader>
        ```

        The shader is WebGL1, GLSL ES 1.00. Rules it must keep: begin with \
        `precision highp float;`; declare only these uniforms — `uniform vec2 \
        u_resolution; uniform float u_time; uniform float u_seed;` (u_mouse, \
        u_delta and u_frame also exist if you want them); define `void main()` and \
        write `gl_FragColor`; no textures, no samplers, no #version, no #include, no \
        layout qualifiers, no in/out declarations, no loops longer than 64 \
        iterations, no functions the ES 1.00 spec lacks (no round, no tanh — write \
        your own). Use `u_seed` to turn the palette and shift the phase so two \
        seeds give two pictures. Keep it under 90 lines. Paint with colour, \
        motion and texture; the given motifs are the ingredients, the feeling is \
        the dish. Never explain the shader; the FEELING line is the only prose.

        GLSL ES 1.00 is strict about types, and the compiler refuses the whole \
        shader for one slip: a float takes only a float (write 1.0, never 1; \
        `float f = p.x;` never `float f = p;`), a vec2 takes only a vec2, and \
        every function argument must match its declared type exactly. \
        `length(p)`, `dot(p, p)` and `sin(x)` return float; `p.xy`, `p * 2.0` \
        return vec2. Declare every variable before use, name every loop bound \
        as a constant, and do not shadow a uniform. A loop counter is an int: \
        convert it with `float(i)` before it touches a float. There are no \
        textures at all: for grain or noise, write it — \
        `fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453)` — never sample one.
        """

    public static func prompt(
        for brief: DanceBrief, recentLines: [String] = [], now: Date = Date()
    ) -> String {
        var lines: [String] = []
        switch brief.subject {
        case .dance:
            lines.append("Compose a shader to dance to — energy and movement, several windows opening and closing to a beat, each with a shader of its own.")
            lines.append("The FEELING line says what the dance feels like, in your own voice.")
            if let variant = brief.variant {
                lines.append("This is shader \(variant.index) of \(variant.of) for the same dance. Make it unlike the others: a different palette, a different kind of motion, a different form — the motifs below are yours alone.")
            }
        case .mary:
            lines.append("They asked how you feel. Compose a shader that shows it, and say the feeling in one honest sentence.")
        case .person:
            lines.append("They asked what you think they feel like right now. Read it from what they said and how, compose a shader that shows it, and say what you read in one gentle sentence.")
        }
        lines.append("They said: \"\(brief.utterance)\"")
        if let hint = brief.moodHint, !hint.isEmpty {
            lines.append("A hint about the mood: \(hint)")
        }
        if !brief.motifs.isEmpty {
            lines.append("Motifs to paint with: \(brief.motifs.joined(separator: ", ")).")
        }
        lines.append("The time is \(timeOfDay(now)).")
        if !recentLines.isEmpty {
            lines.append("The last few things said between you:")
            lines.append(contentsOf: recentLines.suffix(6).map { "  \($0)" })
        }
        if let repair = brief.repair {
            lines.append("")
            lines.append("Your previous shader was refused: \(repair.problem)")
            lines.append("Fix that and answer again in the same shape, whole. The previous shader, numbered the way the compiler counts its lines:")
            lines.append("```glsl")
            lines.append(contentsOf: numbered(repair.glsl))
            lines.append("```")
        }
        return lines.joined(separator: "\n")
    }

    /// The shader as the compiler saw it — its own lines, numbered from one,
    /// fences stripped — so "line 17" in the log is line 17 here.
    static func numbered(_ glsl: String) -> [String] {
        let body: String
        if case .success(let fragment) = GLSLFragment.admit(glsl) {
            body = fragment.source
        } else {
            body = GLSLFragment.fencedBlock(in: glsl)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? glsl
        }
        return body.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { "\($0.offset + 1): \($0.element)" }
    }

    static func timeOfDay(_ date: Date) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        switch hour {
        case 5..<9: return "early morning"
        case 9..<12: return "morning"
        case 12..<14: return "midday"
        case 14..<18: return "afternoon"
        case 18..<22: return "evening"
        default: return "late at night"
        }
    }

    // MARK: - Parsing

    /// The feeling line and the shader. Nil only when there is no shader at
    /// all — a missing FEELING line falls back to the first prose line.
    public static func parse(_ raw: String) -> DanceComposition? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard text.contains("```") || text.contains("main(") else { return nil }

        var feeling: String?
        if let range = text.range(of: #"(?im)^\s*\**\s*feeling\s*\**\s*:\s*(.+)$"#, options: .regularExpression) {
            let line = String(text[range])
            if let colon = line.firstIndex(of: ":") {
                feeling = String(line[line.index(after: colon)...])
            }
        }
        if feeling == nil {
            let prose = text.components(separatedBy: "```").first ?? ""
            feeling = prose.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty && !$0.contains(";") && !$0.hasPrefix("#") }
        }
        let cleaned = (feeling ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "*_\"")))
        let spoken = cleaned.isEmpty ? "Here." : cleaned
        return DanceComposition(
            feeling: spoken.count > maximumFeelingLength
                ? String(spoken.prefix(maximumFeelingLength)) + "…"
                : spoken,
            glsl: text)
    }
}
