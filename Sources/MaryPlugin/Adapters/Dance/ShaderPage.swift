//
//  ShaderPage.swift
//  MaryPlugin
//
//  WHAT: The transformation pipeline — a composer's reply becomes an admitted
//        GLSL fragment, and a fragment becomes a whole page for the canvas.
//  IN:   DanceEngine
//  OUT:  GLSLFragment.admit / ShaderPage.make → CanvasPage
//  PIN:  TOLERANT ON THE WAY IN, STRICT ON THE WAY OUT. A fenced reply, a
//        prefaced reply and a bare shader all read; a shader that names a
//        texture, a version, or no main() is refused with a sentence the
//        composer can be handed back. The page is the bench's proven WebGL1
//        boilerplate and nothing else: no HUD, no editor, one canvas.
//

import Foundation

/// A fragment shader the page will accept.
public struct GLSLFragment: Sendable, Equatable {
    public let source: String

    /// The uniforms the page always provides. A shader may declare them or
    /// not; the page injects whatever it did not.
    public static let uniforms: [(type: String, name: String)] = [
        ("vec2", "u_resolution"), ("float", "u_time"), ("float", "u_delta"),
        ("float", "u_frame"), ("float", "u_seed"), ("vec2", "u_mouse"),
    ]

    public static let byteLimit = 16 * 1024

    /// Read a composer's reply as a shader, or say why not.
    public static func admit(_ raw: String) -> Result<GLSLFragment, ShaderRefusal> {
        let body = fencedBlock(in: raw) ?? raw
        let source = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return .failure(.empty) }
        guard source.utf8.count <= byteLimit else {
            return .failure(.tooLong(bytes: source.utf8.count))
        }
        for (needle, refusal) in forbidden {
            if source.range(of: needle, options: .regularExpression) != nil {
                return .failure(refusal)
            }
        }
        guard source.range(of: #"void\s+main\s*\("#, options: .regularExpression) != nil else {
            return .failure(.noMain)
        }
        guard source.contains("gl_FragColor") else { return .failure(.noFragColor) }
        guard bracesBalance(source) else { return .failure(.unbalancedBraces) }
        return .success(GLSLFragment(source: source))
    }

    /// The constructs WebGL1 cannot take, each with the sentence it earns.
    static let forbidden: [(String, ShaderRefusal)] = [
        (#"^\s*#version"#, .forbidden("a #version directive — the page is WebGL1, GLSL ES 1.00")),
        (#"^\s*#include"#, .forbidden("an #include — there is nothing to include")),
        (#"\bsampler(2D|Cube|3D)\b"#, .forbidden("a sampler — the page has no textures")),
        (#"\btexture(2D|Cube|Lod)?\s*\("#, .forbidden("a texture lookup — the page has no textures")),
        (#"\blayout\s*\("#, .forbidden("a layout qualifier — that is GLSL ES 3.00")),
        (#"^\s*(in|out)\s+(highp|mediump|lowp)?\s*(float|vec[234]|int)\b"#, .forbidden("an in/out declaration — WebGL1 uses varying and gl_FragColor")),
        (#"\bgl_FragData\b"#, .forbidden("gl_FragData — write gl_FragColor")),
    ]

    /// The first fenced block, whatever its tag; nil when there is none.
    public static func fencedBlock(in raw: String) -> String? {
        guard let open = raw.range(of: "```") else { return nil }
        let afterOpen = raw[open.upperBound...]
        // Skip the language tag on the opening line.
        guard let newline = afterOpen.firstIndex(of: "\n") else { return nil }
        let body = afterOpen[afterOpen.index(after: newline)...]
        guard let close = body.range(of: "```") else {
            // AN UNCLOSED FENCE IS A REPLY CUT OFF, not a shader with a stray
            // token: the token ceiling reached before the closing fence.
            return nil
        }
        return String(body[..<close.lowerBound])
    }

    // MARK: - The one repair Mary makes herself

    /// THE SLIP A SMALL MODEL MAKES MOST: an integer where GLSL ES 1.00 wants a
    /// float — `p * 2`, `x / 3`, `vec3(1, 0, 0)` — and the compiler names the
    /// line. Every bare integer literal on the named lines becomes a float
    /// literal, except where an integer is the only right answer: inside `[ ]`,
    /// in a `for` header, after `int`, or as a swizzle/field. A model round
    /// costs seconds; this costs a rehearsal.
    public func floatingIntegerLiterals(onLines lines: Set<Int>) -> GLSLFragment? {
        rewriting(lines: lines) { line, intNames in
            // A line that assigns to an int is int arithmetic and stays so.
            if Self.assignsToInteger(intNames, in: line) { return line }
            return Self.floatingIntegerVariables(intNames, in: Self.floatingIntegers(in: line))
        }
    }

    /// `const float x = u_time * 2.0;` — a constant that is not one. The
    /// compiler names the line; the keyword goes.
    public func droppingConst(onLines lines: Set<Int>) -> GLSLFragment? {
        rewriting(lines: lines) { line, _ in
            line.replacingOccurrences(
                of: #"^(\s*)const\s+"#, with: "$1", options: .regularExpression)
        }
    }

    /// EVERY REPAIR MARY MAKES HERSELF, read off the compiler's log: an int
    /// where a float belongs, a const that is not constant. Nil when the log
    /// names nothing she can fix.
    public func repaired(from log: String) -> GLSLFragment? {
        var current = self
        var changed = false
        if let floated = current.floatingIntegerLiterals(onLines: Self.integerComplaintLines(in: log)) {
            current = floated
            changed = true
        }
        if let unconst = current.droppingConst(onLines: Self.constComplaintLines(in: log)) {
            current = unconst
            changed = true
        }
        return changed ? current : nil
    }

    private func rewriting(
        lines: Set<Int>, _ fix: (String, Set<String>) -> String
    ) -> GLSLFragment? {
        guard !lines.isEmpty else { return nil }
        // THE INT VARIABLES, so `i * 0.5` on a named line becomes
        // `float(i) * 0.5` — the loop counter is the other int a model
        // forgets to convert, and the compiler names the same line for it.
        let intNames = Self.integerVariables(in: source)
        var changed = false
        let rewritten = source.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { index, line -> String in
                guard lines.contains(index + 1) else { return String(line) }
                let fixed = fix(String(line), intNames)
                if fixed != line { changed = true }
                return fixed
            }
            .joined(separator: "\n")
        return changed ? GLSLFragment(source: rewritten) : nil
    }

    static func assignsToInteger(_ names: Set<String>, in line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for name in names {
            let pattern = "^" + NSRegularExpression.escapedPattern(for: name) + #"\s*([-+*/]?=[^=]|\+\+|--)"#
            if trimmed.range(of: pattern, options: .regularExpression) != nil { return true }
        }
        return false
    }

    /// The lines a log names for a constant that is not one.
    public static func constComplaintLines(in log: String) -> Set<Int> {
        complaintLines(in: log) { $0.contains("non-constant") || $0.contains("const") }
    }

    /// Every identifier the shader declares as `int`.
    static func integerVariables(in source: String) -> Set<String> {
        var names: Set<String> = []
        let pattern = #"\bint\s+([A-Za-z_][A-Za-z0-9_]*)"#
        var searchRange = source.startIndex..<source.endIndex
        while let match = source.range(of: pattern, options: .regularExpression, range: searchRange) {
            let declaration = String(source[match])
            if let name = declaration.split(whereSeparator: { $0.isWhitespace }).last {
                names.insert(String(name))
            }
            searchRange = match.upperBound..<source.endIndex
        }
        return names
    }

    /// `i * 0.5` → `float(i) * 0.5` for an int `i`, on this line, where `i`
    /// stands beside an arithmetic operator and not an assignment, an index,
    /// or a loop header.
    static func floatingIntegerVariables(_ names: Set<String>, in line: String) -> String {
        guard !names.isEmpty else { return line }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("for") || trimmed.hasPrefix("int ") { return line }
        var out = line
        for name in names {
            // An operand: an arithmetic operator on one side, nothing that makes
            // it an lvalue, an index or a call on the other.
            let pattern = #"(?<![A-Za-z0-9_.\[(])\b"# + NSRegularExpression.escapedPattern(for: name)
                + #"\b(?=\s*[*/+\-](?!=))|(?<=[*/+\-]\s{0,4})\b"# + NSRegularExpression.escapedPattern(for: name)
                + #"\b(?![A-Za-z0-9_\[(.]|\s*=[^=])"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            out = regex.stringByReplacingMatches(
                in: out, range: range, withTemplate: "float(\(name))")
        }
        return out
    }

    /// The lines a compiler log names ("ERROR: line 30:" as the page spells it,
    /// or "ERROR: 0:30:" raw), only where the complaint is about an int.
    public static func integerComplaintLines(in log: String) -> Set<Int> {
        complaintLines(in: log) { ($0.contains("int") || $0.contains("integer")) && !$0.contains("non-constant") }
    }

    static func complaintLines(in log: String, where matches: (String) -> Bool) -> Set<Int> {
        var lines: Set<Int> = []
        for entry in log.components(separatedBy: " | ") {
            let lowered = entry.lowercased()
            guard matches(lowered) else { continue }
            let pattern = #"(?:line\s+|0:)(\d+):"#
            guard let match = entry.range(of: pattern, options: .regularExpression) else { continue }
            let digits = entry[match].filter(\.isNumber)
            if let number = Int(digits) { lines.insert(number) }
        }
        return lines
    }

    static func floatingIntegers(in line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // A loop header and an int declaration are where integers belong.
        if trimmed.hasPrefix("for") || trimmed.hasPrefix("int ") || trimmed.hasPrefix("const int") { return line }
        let characters = Array(line)
        var out = ""
        var index = 0
        var bracketDepth = 0
        while index < characters.count {
            let character = characters[index]
            if character == "[" { bracketDepth += 1 }
            if character == "]" { bracketDepth = max(0, bracketDepth - 1) }
            guard character.isNumber else {
                out.append(character)
                index += 1
                continue
            }
            // The whole numeric token.
            var end = index
            while end < characters.count, characters[end].isNumber || characters[end] == "." { end += 1 }
            let token = String(characters[index..<end])
            let before = index > 0 ? characters[index - 1] : " "
            let after = end < characters.count ? characters[end] : " "
            let isIdentifierPart = before.isLetter || before == "_" || before == "." || after.isLetter || after == "_"
            let alreadyFloat = token.contains(".") || after == "." || after == "e" || after == "E"
            if bracketDepth == 0, !isIdentifierPart, !alreadyFloat {
                out.append(token + ".0")
            } else {
                out.append(token)
            }
            index = end
        }
        return out
    }

    static func bracesBalance(_ source: String) -> Bool {
        var depth = 0
        for character in source {
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth < 0 { return false }
            }
        }
        return depth == 0
    }
}

/// Why a shader was not admitted, said so the composer can fix it.
public enum ShaderRefusal: Error, Sendable, Equatable {
    case empty
    case tooLong(bytes: Int)
    case noMain
    case noFragColor
    case unbalancedBraces
    case forbidden(String)

    public var summary: String {
        switch self {
        case .empty: return "The reply held no shader."
        case .tooLong(let bytes): return "The shader is \(bytes / 1024) KB; the page takes up to \(GLSLFragment.byteLimit / 1024) KB."
        case .noMain: return "The shader has no main()."
        case .noFragColor: return "The shader never writes gl_FragColor."
        case .unbalancedBraces: return "The shader's braces do not balance — it was probably cut off."
        case .forbidden(let what): return "The shader uses \(what)."
        }
    }
}

/// One whole page: a black body, one canvas, the shader, and the receipt.
public enum ShaderPage {

    /// The page for a shader. `seed` reaches the shader as `u_seed`; `scale`
    /// is the render scale (1 is the display's own pixels, 0.5 a quarter of
    /// the work — for several windows at once).
    public static func make(
        shader: GLSLFragment, title: String, seed: Double = 0, scale: Double = 1
    ) -> CanvasPage {
        CanvasPage(title: title, html: html(shader: shader, title: title, seed: seed, scale: scale))
    }

    static func html(shader: GLSLFragment, title: String, seed: Double, scale: Double) -> String {
        let escapedTitle = title
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        // The shader travels as a JSON string literal, so nothing in it can
        // close the script element or the string.
        let literal = (try? JSONSerialization.data(
            withJSONObject: [shader.source], options: [.withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) }
            .map { String($0.dropFirst().dropLast()) }
            ?? "\"\""
        let safeLiteral = literal.replacingOccurrences(of: "</", with: "<\\/")
        let uniformTable = GLSLFragment.uniforms
            .map { "[\"\($0.type)\",\"\($0.name)\"]" }
            .joined(separator: ",")
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>\(escapedTitle)</title>
        <style>html,body{margin:0;height:100%;overflow:hidden;background:#000}canvas{position:absolute;inset:0;width:100%;height:100%;display:block}</style>
        </head><body><canvas id="gl"></canvas>
        <script>
        "use strict";
        var SOURCE = \(safeLiteral);
        var SEED = \(seed);
        var SCALE = \(scale);
        var AUTO = [\(uniformTable)];
        var VERT = "attribute vec2 a_pos;void main(){gl_Position=vec4(a_pos,0.0,1.0);}";
        function report(ready, log) {
          try { window.webkit.messageHandlers.canvas.postMessage({ready: ready, log: log || null}); } catch (e) {}
        }
        function prefix(src) {
          if (/^\\s*#version/.test(src)) return "";
          var out = ["#ifdef GL_FRAGMENT_PRECISION_HIGH","precision highp float;","#else","precision mediump float;","#endif"];
          for (var i = 0; i < AUTO.length; i++) {
            var declared = new RegExp("\\\\buniform\\\\s+[^;]*\\\\b" + AUTO[i][1] + "\\\\b").test(src);
            if (!declared) out.push("uniform " + AUTO[i][0] + " " + AUTO[i][1] + ";");
          }
          return out.join("\\n") + "\\n";
        }
        // THE LOG COUNTS THE PREFIX. The compiler numbers lines of what it was
        // given, prefix included; the composer only ever saw the shader, so
        // every "0:N" is moved back onto the shader's own line N.
        var PREFIX_LINES = prefix(SOURCE).split("\\n").length - 1;
        function parseLog(log) {
          return (log || "").replace(/\\u0000/g, "").split("\\n").map(function (l) {
            return l.trim().replace(/^(ERROR|WARNING):\\s*0:(\\d+):/i, function (m, kind, n) {
              return kind.toUpperCase() + ": line " + Math.max(1, parseInt(n, 10) - PREFIX_LINES) + ":";
            });
          }).filter(Boolean).join(" | ");
        }
        var canvas = document.getElementById("gl");
        var gl = canvas.getContext("webgl", {antialias: false, alpha: false, preserveDrawingBuffer: false})
              || canvas.getContext("experimental-webgl", {antialias: false, alpha: false});
        if (!gl) { report(false, "no WebGL"); }
        else {
          var vs = gl.createShader(gl.VERTEX_SHADER); gl.shaderSource(vs, VERT); gl.compileShader(vs);
          var fs = gl.createShader(gl.FRAGMENT_SHADER); gl.shaderSource(fs, prefix(SOURCE) + SOURCE); gl.compileShader(fs);
          if (!gl.getShaderParameter(fs, gl.COMPILE_STATUS)) {
            report(false, parseLog(gl.getShaderInfoLog(fs)));
          } else {
            var prog = gl.createProgram(); gl.attachShader(prog, vs); gl.attachShader(prog, fs);
            gl.bindAttribLocation(prog, 0, "a_pos"); gl.linkProgram(prog);
            if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) {
              report(false, parseLog(gl.getProgramInfoLog(prog)));
            } else {
              gl.useProgram(prog);
              var buffer = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
              gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1,-1,3,-1,-1,3]), gl.STATIC_DRAW);
              gl.enableVertexAttribArray(0); gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
              var locs = {};
              for (var j = 0; j < AUTO.length; j++) locs[AUTO[j][1]] = gl.getUniformLocation(prog, AUTO[j][1]);
              var time = 0, frame = 0, last = 0;
              function resize() {
                var dpr = (window.devicePixelRatio || 1) * SCALE;
                var w = Math.max(1, Math.round(canvas.clientWidth * dpr));
                var h = Math.max(1, Math.round(canvas.clientHeight * dpr));
                if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h; }
                gl.viewport(0, 0, w, h);
              }
              function draw(now) {
                requestAnimationFrame(draw);
                var dt = last ? Math.min(0.1, (now - last) / 1000) : 0;
                last = now; time += dt; frame++;
                resize();
                var w = canvas.width, h = canvas.height;
                if (locs.u_resolution) gl.uniform2f(locs.u_resolution, w, h);
                if (locs.u_time) gl.uniform1f(locs.u_time, time + SEED * 7.0);
                if (locs.u_delta) gl.uniform1f(locs.u_delta, dt);
                if (locs.u_frame) gl.uniform1f(locs.u_frame, frame);
                if (locs.u_seed) gl.uniform1f(locs.u_seed, SEED);
                if (locs.u_mouse) gl.uniform2f(locs.u_mouse, w * 0.5, h * 0.5);
                gl.drawArrays(gl.TRIANGLES, 0, 3);
              }
              // THE RECEIPT IS ONE SYNCHRONOUS DRAW, not an animation frame: a
              // hidden window gets no animation frames at all, and the page is
              // rehearsed hidden. Compiled, linked and drawn once with no GL
              // error is what "ready" means; the frames start when it is seen.
              draw(0);
              var error = gl.getError();
              report(error === gl.NO_ERROR, error === gl.NO_ERROR ? null : ("GL error " + error));
              requestAnimationFrame(draw);
            }
          }
        }
        </script></body></html>
        """
    }
}
