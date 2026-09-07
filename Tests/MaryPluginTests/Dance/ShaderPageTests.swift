//
//  ShaderPageTests.swift
//  MaryPluginTests
//
//  WHAT: A composer's reply becomes a shader or a sentence; a shader becomes
//        one whole page.
//  OUT:  GLSLFragment.admit / ShaderPage.make
//

import Foundation
import Testing
@testable import MaryPlugin

@Suite struct ShaderPageTests {

    static let plasma = """
    precision highp float;
    uniform vec2 u_resolution;
    uniform float u_time;
    void main() {
        vec2 p = (2.0*gl_FragCoord.xy - u_resolution.xy) / u_resolution.y;
        float v = sin(p.x*3.2 + u_time) + sin(p.y*3.7 - u_time*1.3);
        vec3 col = 0.5 + 0.5*cos(vec3(0.0, 0.65, 1.15) + v*1.4);
        gl_FragColor = vec4(col, 1.0);
    }
    """

    @Test func aBareShaderIsAdmitted() throws {
        let fragment = try GLSLFragment.admit(Self.plasma).get()
        #expect(fragment.source.hasPrefix("precision highp float;"))
        #expect(fragment.source.contains("gl_FragColor"))
    }

    @Test func aFencedReplyIsReadWhateverItsTag() throws {
        for tag in ["glsl", "", "c", "GLSL"] {
            let reply = "FEELING: Restless, mostly.\n\n```\(tag)\n\(Self.plasma)\n```\nThat's it."
            let fragment = try GLSLFragment.admit(reply).get()
            #expect(fragment.source == Self.plasma.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    @Test func anUnclosedFenceIsACutOffReply() {
        let reply = "```glsl\nprecision highp float;\nvoid main() {\n  gl_FragColor = vec4(1.0);\n"
        switch GLSLFragment.admit(reply) {
        case .success: Issue.record("a cut-off reply was admitted")
        case .failure(let refusal): #expect(refusal == .unbalancedBraces)
        }
    }

    @Test func eachForbiddenConstructEarnsItsSentence() {
        let cases: [(String, String)] = [
            ("#version 300 es\n" + Self.plasma, "#version"),
            (Self.plasma.replacingOccurrences(of: "void main", with: "uniform sampler2D tex;\nvoid main"), "sampler"),
            (Self.plasma.replacingOccurrences(of: "vec4(col, 1.0)", with: "texture2D(t, p)"), "texture"),
            ("layout(location = 0) out vec4 o;\n" + Self.plasma, "layout"),
            ("out vec4 fragColor;\n" + Self.plasma, "in/out"),
            (Self.plasma.replacingOccurrences(of: "gl_FragColor", with: "gl_FragData[0]"), "gl_FragData"),
        ]
        for (source, word) in cases {
            switch GLSLFragment.admit(source) {
            case .success:
                Issue.record("\(word) was admitted")
            case .failure(let refusal):
                guard case .forbidden(let what) = refusal else {
                    if word == "gl_FragData" { continue }   // refused earlier as no gl_FragColor is fine too
                    Issue.record("\(word): \(refusal.summary)")
                    continue
                }
                #expect(what.contains(word), "\(word): \(what)")
            }
        }
    }

    @Test func missingPartsAreNamed() {
        #expect(GLSLFragment.admit("").failureValue == .empty)
        #expect(GLSLFragment.admit("float a = 1.0;").failureValue == .noMain)
        #expect(GLSLFragment.admit("void main() { float a = 1.0; }").failureValue == .noFragColor)
        #expect(GLSLFragment.admit("void main() { gl_FragColor = vec4(1.0); ").failureValue == .unbalancedBraces)
        let long = "void main() { gl_FragColor = vec4(1.0); }" + String(repeating: "// pad\n", count: 4000)
        let trimmed = long.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(GLSLFragment.admit(long).failureValue == .tooLong(bytes: trimmed.utf8.count))
    }

    @Test func thePageHoldsTheShaderAndNothingElse() throws {
        let fragment = try GLSLFragment.admit(Self.plasma).get()
        let page = ShaderPage.make(shader: fragment, title: "How Mary feels", seed: 3, scale: 0.5)
        #expect(page.title == "How Mary feels")
        #expect(page.html.contains("<title>How Mary feels</title>"))
        #expect(page.html.contains("messageHandlers.canvas.postMessage"))
        #expect(page.html.contains("var SEED = 3.0;"))
        #expect(page.html.contains("var SCALE = 0.5;"))
        #expect(page.html.contains("u_seed"))
        #expect(!page.html.contains("evaluateJavaScript"))
        // The compiler's line numbers count the injected prefix; the page moves
        // them back onto the shader's own lines before they reach a repair.
        #expect(page.html.contains("PREFIX_LINES"))
        #expect(page.html.contains("\": line \""))
        #expect(!page.html.contains("<textarea"))
        // The shader travels as one JSON string literal — every newline escaped.
        #expect(page.html.contains("var SOURCE = \"precision highp float;\\n"))
        #expect(page.byteCount < 8 * 1024)
    }

    @Test func aShaderCannotCloseTheScript() throws {
        let sneaky = "void main() { /* </script><script>alert(1)</script> */ gl_FragColor = vec4(1.0); }"
        let fragment = try GLSLFragment.admit(sneaky).get()
        let page = ShaderPage.make(shader: fragment, title: "t")
        #expect(!page.html.contains("</script><script>alert"))
        #expect(page.html.contains("<\\/script>"))
    }

    /// `p * 2` becomes `p * 2.0` on the named line and nowhere else; an index,
    /// a loop counter and a swizzle keep their integers.
    @Test func integersBecomeFloatsOnTheLineTheCompilerNamed() throws {
        let source = """
        precision highp float;
        uniform vec2 u_resolution;
        void main() {
            vec2 p = gl_FragCoord.xy / u_resolution * 2;
            float v = 0;
            for (int i = 0; i < 3; i++) { v += float(i) * 2; }
            vec3 col = vec3(1, 0, 0) + vec3(p.x, p.y, 0.5) * 1e2 * 0.5;
            float a[2]; a[1] = 3;
            gl_FragColor = vec4(col, 1);
        }
        """
        let fragment = try GLSLFragment.admit(source).get()
        let log = "ERROR: line 4: '*' : wrong operand types - no operation '*' exists that takes a left-hand operand of type 'highp 2-component vector of float' and a right operand of type 'const int' | ERROR: line 7: '+' : wrong operand types int | ERROR: line 8: 'assign' : cannot convert from 'const int' to 'highp float' | ERROR: line 6: something about int"
        #expect(GLSLFragment.integerComplaintLines(in: log) == [4, 6, 7, 8])
        let fixed = try #require(fragment.floatingIntegerLiterals(onLines: [4, 6, 7, 8, 9]))
        let lines = fixed.source.split(separator: "\n").map(String.init)
        #expect(lines[3].hasSuffix("u_resolution * 2.0;"))
        #expect(lines[5].contains("for (int i = 0; i < 3; i++)"), "a loop header keeps its integers")
        #expect(lines[6].contains("vec3(1.0, 0.0, 0.0)"))
        #expect(lines[6].contains("* 1e2 * 0.5"), "a float stays a float")
        #expect(lines[7].contains("a[1] = 3.0"), "the index stays, the value floats")
        #expect(lines[8].contains("vec4(col, 1.0)"))
        #expect(fragment.floatingIntegerLiterals(onLines: [1]) == nil, "nothing to float on line 1")
        #expect(fragment.floatingIntegerLiterals(onLines: []) == nil)
        #expect(GLSLFragment.integerComplaintLines(in: "ERROR: line 3: 'x' : undeclared identifier").isEmpty)
    }

    /// A loop counter in float arithmetic is wrapped; the loop header, an
    /// index and an assignment are left alone.
    @Test func integerVariablesAreWrappedOnTheLineTheCompilerNamed() throws {
        let source = """
        precision highp float;
        void main() {
            float v = 0.0;
            for (int i = 0; i < 4; i++) {
                v += i * 0.25;
                v = v + 0.5 * i - i;
            }
            int k = 2;
            float a[4]; v += a[k];
            k = k + 1;
            gl_FragColor = vec4(v * float(k), 0.0, 0.0, 1.0);
        }
        """
        let fragment = try GLSLFragment.admit(source).get()
        #expect(GLSLFragment.integerVariables(in: source) == ["i", "k"])
        let fixed = try #require(fragment.floatingIntegerLiterals(onLines: [4, 5, 6, 9, 10, 11]))
        let lines = fixed.source.split(separator: "\n").map(String.init)
        #expect(lines[3].contains("for (int i = 0; i < 4; i++)"))
        #expect(lines[4].contains("v += float(i) * 0.25;"))
        #expect(lines[5].contains("v = v + 0.5 * float(i) - float(i);"))
        #expect(lines[8].contains("a[k]"), "an index stays an int")
        #expect(lines[9].contains("k = k + 1;"), "a line assigning to an int is int arithmetic: \(lines[9])")
        #expect(lines[10].contains("v * float(k)"), "already wrapped stays: \(lines[10])")
        #expect(!lines[10].contains("float(float(k))"))
    }

    /// A const initialised from a uniform loses its keyword on the named line.
    @Test func aConstThatIsNotOneIsUnconsted() throws {
        let source = "precision highp float;\nuniform float u_time;\nvoid main() {\n    const float t = u_time * 2.0;\n    const float pi = 3.14159;\n    gl_FragColor = vec4(t * pi);\n}"
        let fragment = try GLSLFragment.admit(source).get()
        let log = "ERROR: line 4: '=' : assigning non-constant to 'const highp float'"
        #expect(GLSLFragment.constComplaintLines(in: log) == [4])
        #expect(GLSLFragment.integerComplaintLines(in: log).isEmpty)
        let fixed = try #require(fragment.repaired(from: log))
        let lines = fixed.source.split(separator: "\n").map(String.init)
        #expect(lines[3] == "    float t = u_time * 2.0;")
        #expect(lines[4] == "    const float pi = 3.14159;", "a real constant keeps its keyword")
        #expect(fragment.repaired(from: "ERROR: line 2: 'foo' : undeclared identifier") == nil)
    }

    @Test func motifsComeFromTheVocabulary() {
        let motifs = DanceMotifs.pick(random: { _ in 0.999 })
        #expect(motifs.count == 3)
        #expect(DanceMotifs.palettes.contains(motifs[0]))
        #expect(DanceMotifs.motions.contains(motifs[1]))
        #expect(DanceMotifs.textures.contains(motifs[2]))
        #expect(DanceMotifs.pick(random: { _ in 0 }) == [DanceMotifs.palettes[0], DanceMotifs.motions[0], DanceMotifs.textures[0]])
    }
}

private extension Result where Failure == ShaderRefusal {
    var failureValue: ShaderRefusal? {
        if case .failure(let refusal) = self { return refusal }
        return nil
    }
}
