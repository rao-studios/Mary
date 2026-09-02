//
//  LayoutDisciplineTests.swift
//  MaryFoundationTests
//
//  WHAT: No hard-coded container size outside Paper.Layout's tokens.
//  OUT:  Scan of Sources/MaryApp for `.frame` literals, sheet/popover
//        pairing, scene root modifiers, and Paper.Layout's own arithmetic.
//  PIN:  An allow-list entry must still offend, or it has gone stale.
//

import Foundation
import Testing

@Suite struct LayoutDisciplineTests {

    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaryFoundationTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }

    static var maryAppRoot: URL {
        repositoryRoot.appendingPathComponent("Sources/MaryApp", isDirectory: true)
    }

    /// Below this, a `.frame` literal is an atom (icon, divider, gutter) —
    /// not a column pretending to be one. Mirrors `Paper.Layout.atom`.
    static let atom: Double = 160

    // MARK: - Scanning

    /// Source with `//` and `/* */` comments removed, newlines preserved so
    /// a reported line number still means something. Same shape as
    /// `BrandTokenTests.stripComments`.
    static func stripComments(_ source: String) -> String {
        var output = ""
        var inBlockComment = false
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            var kept = ""
            var index = line.startIndex
            while index < line.endIndex {
                let rest = line[index...]
                if inBlockComment {
                    if let close = rest.range(of: "*/") {
                        inBlockComment = false
                        index = close.upperBound
                    } else {
                        index = line.endIndex
                    }
                    continue
                }
                if rest.hasPrefix("//") { break }
                if rest.hasPrefix("/*") {
                    inBlockComment = true
                    index = line.index(index, offsetBy: 2)
                    continue
                }
                kept.append(line[index])
                index = line.index(after: index)
            }
            output.append(kept)
            output.append("\n")
        }
        return output
    }

    static func files(under directory: URL, extensions: Set<String>) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return walker.compactMap { $0 as? URL }
            .filter { extensions.contains($0.pathExtension) }
            .sorted { $0.path < $1.path }
    }

    /// One `.frame(...)` call's argument text, paren-balanced past one
    /// nested level — enough for `.frame(width: canReorder ? 54 : 20)`
    /// shapes. A call with two nested levels is outside this gate's reach,
    /// the same blind spot `BrandTokenTests.stripComments` documents for
    /// its own scan.
    static let framePattern = try! NSRegularExpression(
        pattern: #"\.frame\(((?:[^()]|\([^()]*\))*)\)"#)

    /// A `width`/`minWidth`/`height`/`minHeight` literal inside one `.frame`
    /// argument list. `maxWidth`/`maxHeight`/`idealWidth` are caps, not
    /// floors, and never offend. Requires a digit after the colon, so an
    /// expression like `Paper.Layout.rail.ideal` or `geo.size.width` never
    /// matches.
    static let literalPattern = try! NSRegularExpression(
        pattern: #"(?:^|,)\s*(width|minWidth|height|minHeight)\s*:\s*(\d+(?:\.\d+)?)"#)

    /// Every `.frame` literal at or above `atom`, with its 1-based line and
    /// the argument text it was found in.
    static func offences(in source: String) -> [(line: Int, argument: String)] {
        let stripped = stripComments(source)
        let ns = stripped as NSString
        var results: [(Int, String)] = []
        framePattern.enumerateMatches(in: stripped, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, let range = Range(match.range(at: 1), in: stripped) else { return }
            let arguments = String(stripped[range])
            let argNS = arguments as NSString
            // A height paired with its own maxHeight is already the bounded
            // span rule 4 asks for (a scroll region's floor and ceiling) —
            // not a rigid literal. A width has no such exemption: column
            // widths are the shared, cross-view concern this gate exists for.
            let hasMaxHeight = arguments.contains("maxHeight")
            var offends = false
            literalPattern.enumerateMatches(in: arguments, range: NSRange(location: 0, length: argNS.length)) { inner, _, _ in
                guard let inner,
                      let keyRange = Range(inner.range(at: 1), in: arguments),
                      let valueRange = Range(inner.range(at: 2), in: arguments),
                      let value = Double(arguments[valueRange])
                else { return }
                guard value >= atom else { return }
                let key = arguments[keyRange]
                if (key == "height" || key == "minHeight") && hasMaxHeight { return }
                offends = true
            }
            guard offends else { return }
            let offset = match.range(at: 1).location
            let line = ns.substring(to: offset).filter { $0 == "\n" }.count + 1
            results.append((line, arguments.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return results
    }

    // MARK: - (a) No literal container size

    /// Files where a literal container size is still allowed, one phase at
    /// a time. `everyAllowedFileStillOffends` keeps this list honest.
    /// Empty: every file this scan once carried has been converted to a
    /// `Paper.Layout` span. `everyAllowedFileStillOffends` has nothing left
    /// to check and stays only as the guard against a future entry going
    /// stale unnoticed.
    static let allowed: Set<String> = []

    @Test func noLiteralContainerSizeOutsideTheAllowList() throws {
        var reports: [String] = []
        for file in Self.files(under: Self.maryAppRoot, extensions: ["swift"]) {
            if Self.allowed.contains(file.lastPathComponent) { continue }
            let source = try String(contentsOf: file, encoding: .utf8)
            for hit in Self.offences(in: source) {
                reports.append("\(file.lastPathComponent):\(hit.line) — \(hit.argument)")
            }
        }
        #expect(reports.isEmpty, """
            \(reports.count) literal container size(s) outside Paper.Layout. A \
            `.frame` width or height of \(Int(Self.atom)) or more is a column in \
            disguise — give it a `Paper.Layout` span and `.maryColumn(_:)` instead.

            \(reports.prefix(20).joined(separator: "\n"))
            """)
    }

    /// AN ALLOW-LIST ENTRY EARNS ITS PLACE ONLY WHILE IT STILL OFFENDS. A
    /// file fixed and left on the list would silently stop being checked.
    @Test func everyAllowedFileStillOffends() throws {
        var stale: [String] = []
        let all = Self.files(under: Self.maryAppRoot, extensions: ["swift"])
        for name in Self.allowed {
            guard let file = all.first(where: { $0.lastPathComponent == name }) else {
                stale.append("\(name) no longer exists"); continue
            }
            let source = try String(contentsOf: file, encoding: .utf8)
            if Self.offences(in: source).isEmpty {
                stale.append("\(name) no longer offends — remove it from `allowed`")
            }
        }
        #expect(stale.isEmpty, "\(stale.joined(separator: "\n"))")
    }

    // MARK: - (b) Sheets and popovers size to the window

    @Test func everySheetSizesToTheWindow() throws {
        var offenders: [String] = []
        for file in Self.files(under: Self.maryAppRoot, extensions: ["swift"])
        where file.lastPathComponent.hasSuffix("Sheet.swift") {
            guard !Self.allowed.contains(file.lastPathComponent) else { continue }
            let source = Self.stripComments(try String(contentsOf: file, encoding: .utf8))
            if !source.contains(".marySheet(") { offenders.append(file.lastPathComponent) }
        }
        #expect(offenders.isEmpty, "sheet(s) do not size to the window: \(offenders.joined(separator: ", "))")
    }

    @Test func everyPopoverSizesToTheWindow() throws {
        var offenders: [String] = []
        for file in Self.files(under: Self.maryAppRoot, extensions: ["swift"]) {
            guard !Self.allowed.contains(file.lastPathComponent) else { continue }
            let source = Self.stripComments(try String(contentsOf: file, encoding: .utf8))
            guard source.contains(".popover(") else { continue }
            if !source.contains(".maryPopover(") { offenders.append(file.lastPathComponent) }
        }
        #expect(offenders.isEmpty, "popover(s) do not size to the window: \(offenders.joined(separator: ", "))")
    }

    // MARK: - (c) Scenes carry the window root

    @Test func everySceneCarriesTheWindowRoot() throws {
        let file = Self.repositoryRoot.appendingPathComponent("Sources/MaryApp/MaryApp.swift")
        let source = Self.stripComments(try String(contentsOf: file, encoding: .utf8))
        func count(_ pattern: String) -> Int {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
            return regex.numberOfMatches(in: source, range: NSRange(source.startIndex..., in: source))
        }
        let scenes = count(#"WindowGroup\s*\{"#) + count(#"\bWindow\("#)
        #expect(scenes >= 2, "expected at least two scenes in MaryApp.swift")
        #expect(count(#"\.maryWindow\(floor:"#) == scenes, "every scene must call .maryWindow(floor:)")
        #expect(count(#"\.defaultSize\("#) == scenes, "every scene must call .defaultSize(")
        #expect(count(#"\.windowResizability\(\.contentMinSize\)"#) == scenes,
                "every scene must call .windowResizability(.contentMinSize)")
    }

    // MARK: - (d) Token arithmetic

    static func cgSize(_ name: String, in source: String) -> CGSize? {
        guard let regex = try? NSRegularExpression(
            pattern: "\(NSRegularExpression.escapedPattern(for: name))\\s*=\\s*CGSize\\(width:\\s*(\\d+(?:\\.\\d+)?),\\s*height:\\s*(\\d+(?:\\.\\d+)?)\\)"),
            let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
            let wRange = Range(match.range(at: 1), in: source),
            let hRange = Range(match.range(at: 2), in: source),
            let w = Double(source[wRange]), let h = Double(source[hRange])
        else { return nil }
        return CGSize(width: w, height: h)
    }

    static func span(_ name: String, in source: String) -> (min: Double, ideal: Double, max: Double)? {
        guard let regex = try? NSRegularExpression(
            pattern: "\(NSRegularExpression.escapedPattern(for: name))\\s*=\\s*Span\\(min:\\s*(\\d+(?:\\.\\d+)?),\\s*ideal:\\s*(\\d+(?:\\.\\d+)?),\\s*max:\\s*(\\.infinity|\\d+(?:\\.\\d+)?)\\)"),
            let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
            let minRange = Range(match.range(at: 1), in: source),
            let idealRange = Range(match.range(at: 2), in: source),
            let maxRange = Range(match.range(at: 3), in: source),
            let min = Double(source[minRange]), let ideal = Double(source[idealRange])
        else { return nil }
        let maxText = source[maxRange]
        guard let max = maxText == ".infinity" ? Double.infinity : Double(maxText) else { return nil }
        return (min, ideal, max)
    }

    static func number(_ name: String, in source: String) -> Double? {
        guard let regex = try? NSRegularExpression(
            pattern: "\(NSRegularExpression.escapedPattern(for: name))(?::\\s*CGFloat)?\\s*=\\s*(\\d+(?:\\.\\d+)?)"),
            let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
            let range = Range(match.range(at: 1), in: source),
            let value = Double(source[range])
        else { return nil }
        return value
    }

    /// Reads `Paper+Layout.swift` as text — the `PackageLayeringTests`
    /// idiom — and checks the inequalities the whole standard depends on:
    /// every floor fits inside its window at the compact class, and every
    /// span is internally ordered.
    @Test func tokenArithmeticHolds() throws {
        let file = Self.repositoryRoot.appendingPathComponent("Sources/MaryApp/Core/Paper+Layout.swift")
        let source = Self.stripComments(try String(contentsOf: file, encoding: .utf8))

        guard let homeFloor = Self.cgSize("homeFloor", in: source),
              let studioFloor = Self.cgSize("studioFloor", in: source),
              let conversation = Self.span("conversation", in: source),
              let sidePane = Self.span("sidePane", in: source),
              let splitAllowance = Self.number("splitAllowance", in: source),
              let rail = Self.span("rail", in: source),
              let column = Self.span("column", in: source),
              let studioMain = Self.span("studioMain", in: source),
              let drawer = Self.span("drawer", in: source),
              let dualPanelWidth = Self.number("dualPanelWidth", in: source),
              let regularWidth = Self.number("regularWidth", in: source),
              let wideWidth = Self.number("wideWidth", in: source)
        else {
            Issue.record("could not parse one or more Paper.Layout tokens from Paper+Layout.swift")
            return
        }

        let oneGutter = 48.0
        let bothGutters = 64.0
        #expect(conversation.min + sidePane.min + splitAllowance <= homeFloor.width)
        #expect(rail.min + column.min + studioMain.min + oneGutter <= studioFloor.width)
        #expect(drawer.min + column.min + studioMain.min + oneGutter <= studioFloor.width)
        #expect(rail.min + column.min + studioMain.min + drawer.min + bothGutters <= dualPanelWidth)
        for span in [conversation, sidePane, rail, column, studioMain, drawer] {
            #expect(span.min <= span.ideal)
            #expect(span.ideal <= span.max)
        }
        #expect(regularWidth > homeFloor.width)
        #expect(regularWidth > studioFloor.width)
        #expect(wideWidth > regularWidth)
    }

    // MARK: - Self-tests — the gate has teeth

    @Test func theGateCatchesALiteralColumnWidth() {
        #expect(Self.offences(in: ".frame(width: 420)").count == 1)
    }

    @Test func theGateCatchesAMultilineLiteral() {
        let planted = ".frame(\n    width: 480,\n    height: 560)"
        #expect(Self.offences(in: planted).count == 1)
    }

    @Test func theGateIgnoresAtomsAndTokens() {
        #expect(Self.offences(in: ".frame(width: 1, height: 20)").isEmpty)
        #expect(Self.offences(in: ".frame(width: Paper.Layout.rail.ideal)").isEmpty)
        #expect(Self.offences(in: ".frame(maxWidth: 360)").isEmpty)
        #expect(Self.offences(in: "// .frame(width: 900)").isEmpty)
    }

    /// A bounded height (rule 4's own remedy) is not the disease. Width gets
    /// no such exemption — column widths are cross-view, so a min/max pair
    /// still belongs on a named `Paper.Layout` span.
    @Test func theGateExemptsABoundedHeightButNotAWidth() {
        #expect(Self.offences(in: ".frame(minHeight: 220, maxHeight: 360)").isEmpty)
        #expect(Self.offences(in: ".frame(minWidth: 300, maxWidth: 520)").count == 1)
    }

    @Test func theGateCountsBothDimensionsOnOneCall() {
        #expect(Self.offences(in: ".frame(minWidth: 260, maxWidth: 340)").count == 1)
    }
}
