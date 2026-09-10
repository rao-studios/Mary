//
//  AwarenessAdapter.swift
//  MaryPlugin
//
//  WHAT: The awareness faculty — the unit in front of the user, and what
//        reaches it.
//  IN:   AwarenessSiteResolver / CorpusDeclarationIndex / CorpusTracer
//  OUT:  SkillOutcome (awareness.mary binds every operation here)
//  PIN:  Generic by construction: it serves whichever application declared a
//        dependency on awareness, and no line here names one. Reads only —
//        this faculty has no write and never takes the stage.
//

import Foundation
import MaryAmbient
import MaryFoundation
import os

public struct AwarenessAdapter: MaryAdapter {

    public let name = "awareness"
    public let summary =
        "reads the declaration or passage the user is inside, and traces what reaches it and what it reaches"

    /// Empty on purpose — claiming an app would collide with the package that
    /// owns it. `ProjectCorpusAdapter`'s own rule.
    public let applicationIdentifiers: Set<String> = []
    public let abilities: Set<AbilityID> = [.awareness]

    private let support: AwarenessSupport

    /// What one TURN may spend building a cold project index. Well inside the
    /// pre-lane budget, so a first question about a large repository comes
    /// back with fewer bearings rather than none at all.
    public static let indexBudget: TimeInterval = 1.2

    public init(support: AwarenessSupport = .shared) {
        self.support = support
    }

    /// What Mary's own standing awareness asks for, before either lane speaks.
    public var awarenessRead: AwarenessRead? {
        AwarenessRead(unit: "read_enclosing_unit", surroundings: "trace_surroundings")
    }

    public var skillBindings: [SkillBinding] {
        [readEnclosingUnit, traceSurroundings, traceCallers, traceCallees, searchNeighbourhood]
    }

    public var adapterManifest: InstalledAdapterManifest {
        let adapterID = AdapterID.normalized(name)
        func operation(_ operation: String) -> InstalledAdapterBinding {
            InstalledAdapterBinding(
                adapterID: adapterID,
                operation: operation,
                capabilities: ["awareness.read"],
                inputTypes: [],
                outputTypes: ["awareness.evidence"],
                targetClasses: ["code-workspace", "writing-project"])
        }
        return InstalledAdapterManifest(
            adapterID: adapterID,
            // Spoken title — an unavailable adapter reports as
            // "The \(title) adapter is unavailable".
            title: "Awareness",
            transport: .accessibility,
            operations: [
                operation("read_enclosing_unit"),
                operation("trace_surroundings"),
                operation("trace_callers"),
                operation("trace_callees"),
                operation("search_neighbourhood"),
            ],
            supportedValueTypes: ["awareness.evidence"],
            grantedPermissions: [.accessibility, .files])
    }

    static let log = Logger(subsystem: "nyc.rao.mary", category: "awareness")

    // MARK: - The unit

    private var readEnclosingUnit: SkillBinding {
        SkillBinding(
            name: "read_enclosing_unit",
            description: """
            Read the WHOLE declaration, function or passage the cursor or \
            highlight sits inside — not the window onto it that you can \
            already see. Call this when the user asks what something does, \
            whether it is right, or what you think of it, rather than \
            answering from the excerpt on screen.
            """,
            parameters: [
                .init(
                    name: "symbol", type: "string",
                    description: "A named declaration instead of the one at the cursor.",
                    required: false),
                .init(
                    name: "app", type: "string",
                    description: "Which application. Omit for the one in front.",
                    required: false),
            ],
            access: .read,
            backing: .native { arguments, _ in
                let support = support
                guard let site = AwarenessSiteResolver.resolve(
                    named: arguments["app"], support: support)
                else { return Self.nothingFollowed(support: support) }

                guard let unit = Self.unit(
                    at: site, symbol: arguments["symbol"])
                else {
                    Self.log.info("read_enclosing_unit — no unit at the cursor")
                    return SkillOutcome(
                        ok: true,
                        summary: "I can't tell which declaration the cursor is in.",
                        foundNothing: true)
                }
                AwarenessMemo.shared.note(site: site, unit: unit)
                let header = "\(site.fileName) — \(unit.display), "
                    + "lines \(unit.startLine) to \(unit.endLine)"
                    + (unit.isWhole ? "" : " (the first part of it)")
                let line = "read_enclosing_unit — \(unit.display) chars=\(unit.body.count)"
                Self.log.info("\(line, privacy: .public)")
                return SkillOutcome(
                    ok: true,
                    summary: "\(header):\n\(unit.body)",
                    archivePolicy: .stateSnapshot,
                    adapterTrail: [AdapterID.normalized(name)])
            })
    }

    // MARK: - The surroundings

    private var traceSurroundings: SkillBinding {
        SkillBinding(
            name: "trace_surroundings",
            description: """
            Trace what reaches the code or passage in front of the user and \
            what it reaches — callers, callees, and the places in the project \
            that match what they asked about. Real file and line references, \
            read this turn.
            """,
            parameters: [
                .init(
                    name: "query", type: "string",
                    description: "What they asked, in their own words. Omit to trace the unit alone.",
                    required: false),
                .init(
                    name: "app", type: "string",
                    description: "Which application. Omit for the one in front.",
                    required: false),
            ],
            access: .read,
            backing: .native { arguments, _ in
                let support = support
                guard let site = AwarenessSiteResolver.resolve(
                    named: arguments["app"], support: support)
                else { return Self.nothingFollowed(support: support) }
                guard let root = site.root, let corpus = site.corpus else {
                    return SkillOutcome(
                        ok: true,
                        summary: "I can't see a project around \(site.fileName) to trace through.",
                        foundNothing: true)
                }

                let unit = AwarenessMemo.shared.unit(for: site)
                    ?? Self.unit(at: site, symbol: nil)
                if let unit { AwarenessMemo.shared.note(site: site, unit: unit) }

                let declarations = CorpusDeclarationIndexCache.shared.index(
                    root: root, corpus: corpus, within: Self.indexBudget)
                let callers = unit.map {
                    CorpusTracer.callers(
                        of: $0.name, root: root, corpus: corpus,
                        declarations: declarations)
                } ?? []
                let callees = unit.map {
                    CorpusTracer.callees(
                        in: $0.body, own: $0.name, corpus: corpus,
                        declarations: declarations, in: site.relativePath)
                } ?? []

                // The words they used, looked for where they work. Only when
                // they asked something — a standing trace is about the unit.
                let query = arguments["query"]?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                var matches: [TraceHit] = []
                var searched: String?
                if let query, !query.isEmpty {
                    for word in CorpusTracer.contentWords(of: query) {
                        guard matches.isEmpty else { break }
                        let found = CorpusTracer.search(
                            for: word, root: root, corpus: corpus,
                            declarations: declarations)
                        if !found.isEmpty {
                            matches = found
                            searched = word
                        }
                    }
                }

                guard let brief = AwarenessBrief.surroundings(
                    unit: unit, fileName: site.fileName,
                    callers: callers, callees: callees,
                    matches: matches, query: searched)
                else {
                    Self.log.info("trace_surroundings — nothing to say")
                    return SkillOutcome(
                        ok: true,
                        summary: "Nothing in the project reaches what they're looking at.",
                        foundNothing: true)
                }
                let line = "trace_surroundings — callers=\(callers.count)"
                    + " callees=\(callees.count) matches=\(matches.count)"
                Self.log.info("\(line, privacy: .public)")
                return SkillOutcome(
                    ok: true,
                    summary: brief,
                    archivePolicy: .stateSnapshot,
                    // The standing brief already files this place's identity;
                    // a second generic read fact would only spend the budget.
                    ambientDeposited: true,
                    adapterTrail: [AdapterID.normalized(name)])
            })
    }

    // MARK: - Asked by name

    private var traceCallers: SkillBinding {
        SkillBinding(
            name: "trace_callers",
            description: """
            Find where a named type or function is used across the live \
            project, with the file, the line, and the declaration each use \
            sits inside.
            """,
            parameters: [
                .init(name: "symbol", type: "string",
                      description: "The name to trace.", required: true),
                .init(name: "project", type: "string",
                      description: "Which project. Omit for the one in front.", required: false),
            ],
            access: .read,
            backing: .native { arguments, _ in
                let support = support
                guard let wanted = arguments["symbol"]?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !wanted.isEmpty
                else { return SkillOutcome(ok: false, summary: "Which name?") }
                switch Self.project(named: arguments["project"], support: support) {
                case .refused(let outcome): return outcome
                case .ready(let site, let root, let corpus):
                    let declarations = CorpusDeclarationIndexCache.shared.index(
                        root: root, corpus: corpus, within: Self.indexBudget)
                    let hits = CorpusTracer.callers(
                        of: wanted, root: root, corpus: corpus,
                        declarations: declarations)
                    guard !hits.isEmpty else {
                        return SkillOutcome(
                            ok: true,
                            summary: declarations.declares(wanted)
                                ? (declarations.isComplete
                                    ? "Nothing I can see reaches \(wanted)."
                                    : "I haven't finished reading the project — nothing reaching \(wanted) so far.")
                                : "I don't see anything called \(wanted) in \(site.registration.displayName)'s project.",
                            foundNothing: true)
                    }
                    return SkillOutcome(
                        ok: true,
                        summary: "\(wanted) is reached from:\n"
                            + hits.map(AwarenessBrief.line).joined(separator: "\n"),
                        archivePolicy: .stateSnapshot,
                        adapterTrail: [AdapterID.normalized(name)])
                }
            })
    }

    private var traceCallees: SkillBinding {
        SkillBinding(
            name: "trace_callees",
            description: """
            Find what a named type or function reaches — the declarations its \
            own body calls or holds, resolved to where they live.
            """,
            parameters: [
                .init(name: "symbol", type: "string",
                      description: "The name to trace.", required: true),
                .init(name: "project", type: "string",
                      description: "Which project. Omit for the one in front.", required: false),
            ],
            access: .read,
            backing: .native { arguments, _ in
                let support = support
                guard let wanted = arguments["symbol"]?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !wanted.isEmpty
                else { return SkillOutcome(ok: false, summary: "Which name?") }
                switch Self.project(named: arguments["project"], support: support) {
                case .refused(let outcome): return outcome
                case .ready(_, let root, let corpus):
                    let declarations = CorpusDeclarationIndexCache.shared.index(
                        root: root, corpus: corpus, within: Self.indexBudget)
                    guard let declaration = declarations.declarations(named: wanted).first,
                          let file = CorpusTextCache.shared.text(
                            relativePath: declaration.relativePath,
                            root: root, corpus: corpus),
                          let unit = EnclosingUnit.locate(
                            in: file.source,
                            caret: EnclosingUnit.offset(
                                ofLine: declaration.line,
                                in: file.source.split(
                                    separator: "\n", omittingEmptySubsequences: false
                                ).map(String.init)),
                            corpus: corpus)
                    else {
                        return SkillOutcome(
                            ok: true,
                            summary: "I can't find \(wanted) declared in the project.",
                            foundNothing: true)
                    }
                    let hits = CorpusTracer.callees(
                        in: unit.body, own: wanted, corpus: corpus,
                        declarations: declarations, in: declaration.relativePath)
                    guard !hits.isEmpty else {
                        return SkillOutcome(
                            ok: true,
                            summary: "\(wanted) doesn't reach anything else in the project.",
                            foundNothing: true)
                    }
                    return SkillOutcome(
                        ok: true,
                        summary: "\(wanted) reaches:\n"
                            + hits.map(AwarenessBrief.line).joined(separator: "\n"),
                        archivePolicy: .stateSnapshot,
                        adapterTrail: [AdapterID.normalized(name)])
                }
            })
    }

    private var searchNeighbourhood: SkillBinding {
        SkillBinding(
            name: "search_neighbourhood",
            description: """
            Search the live project around what the user is working on and \
            return the real matching lines, each with its file and line number.
            """,
            parameters: [
                .init(name: "query", type: "string",
                      description: "The word or phrase to look for.", required: true),
                .init(name: "project", type: "string",
                      description: "Which project. Omit for the one in front.", required: false),
            ],
            access: .read,
            backing: .native { arguments, _ in
                let support = support
                guard let wanted = arguments["query"]?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !wanted.isEmpty
                else { return SkillOutcome(ok: false, summary: "What should I look for?") }
                switch Self.project(named: arguments["project"], support: support) {
                case .refused(let outcome): return outcome
                case .ready(_, let root, let corpus):
                    let declarations = CorpusDeclarationIndexCache.shared.index(
                        root: root, corpus: corpus, within: Self.indexBudget)
                    let hits = CorpusTracer.search(
                        for: wanted, root: root, corpus: corpus,
                        declarations: declarations)
                    guard !hits.isEmpty else {
                        return SkillOutcome(
                            ok: true,
                            summary: "Nothing in the project mentions \(wanted).",
                            foundNothing: true)
                    }
                    return SkillOutcome(
                        ok: true,
                        summary: "\(wanted) in the project:\n"
                            + hits.map(AwarenessBrief.line).joined(separator: "\n"),
                        archivePolicy: .stateSnapshot,
                        adapterTrail: [AdapterID.normalized(name)])
                }
            })
    }

    // MARK: - Resolving

    enum Project {
        case ready(AwarenessSite, String, PluginCorpusSchema)
        case refused(SkillOutcome)
    }

    /// The project a by-name question addresses. Failure is a spoken sentence,
    /// not an error — `ProjectCorpusAdapter`'s own shape.
    static func project(named: String?, support: AwarenessSupport) -> Project {
        guard let site = AwarenessSiteResolver.resolve(named: named, support: support)
        else { return .refused(nothingFollowed(support: support)) }
        guard let root = site.root, let corpus = site.corpus else {
            return .refused(SkillOutcome(
                ok: true,
                summary: "I can't see a project around \(site.fileName) to search.",
                foundNothing: true))
        }
        return .ready(site, root, corpus)
    }

    /// The unit at the caret, or a named one anywhere in the same file.
    public static func unit(at site: AwarenessSite, symbol: String?) -> EnclosingUnit? {
        if let symbol = symbol?.trimmingCharacters(in: .whitespacesAndNewlines),
           !symbol.isEmpty {
            // A named declaration IN THIS FILE — the caret moves to it rather
            // than the question changing file, which is what the model means
            // when it asks about a symbol it can already see.
            let lines = site.text.split(
                separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let patterns = site.corpus?.relations.declarations ?? []
            let masked = CorpusText(source: site.text, filename: "").code
            for pattern in patterns {
                for capture in CorpusPatterns.capturesWithLines(pattern, in: masked)
                where capture.name == symbol {
                    let offset = EnclosingUnit.offset(ofLine: capture.line, in: lines)
                    if let found = EnclosingUnit.locate(
                        in: site.text, caret: offset, corpus: site.corpus) {
                        return found
                    }
                }
            }
            return nil
        }
        // A highlight is what they mean; the caret is where they are.
        let caret = site.highlight?.lowerBound ?? site.caret
        return EnclosingUnit.locate(
            in: site.text, caret: caret,
            corpus: site.corpus, highlight: site.highlight)
    }

    /// Nobody asked to be followed, or nobody followed is in front.
    static func nothingFollowed(support: AwarenessSupport) -> SkillOutcome {
        SkillOutcome(
            ok: true,
            summary: support.all.isEmpty
                ? "Nothing I'm watching has asked me to follow its work."
                : "I'm not looking at anything I follow right now.",
            foundNothing: true)
    }
}

/// The unit resolved this turn, so the second question does not redo the
/// first's Accessibility read.
///
/// SHORT, AND KEYED TO THE PLACE: `read_enclosing_unit` and
/// `trace_surroundings` run back to back inside one pre-lane pass, and the
/// caret cannot honestly be assumed to still be there a turn later.
final class AwarenessMemo: @unchecked Sendable {

    static let shared = AwarenessMemo()

    static let lifetime: TimeInterval = 5

    private struct Entry {
        var key: String
        var unit: EnclosingUnit
        var at: Date
    }

    private let box = OSAllocatedUnfairLock<Entry?>(initialState: nil)

    func note(site: AwarenessSite, unit: EnclosingUnit, at now: Date = Date()) {
        box.withLock { $0 = Entry(key: Self.key(for: site), unit: unit, at: now) }
    }

    func unit(for site: AwarenessSite, at now: Date = Date()) -> EnclosingUnit? {
        box.withLock { held in
            guard let held, held.key == Self.key(for: site),
                  now.timeIntervalSince(held.at) < Self.lifetime
            else { return nil }
            return held.unit
        }
    }

    static func key(for site: AwarenessSite) -> String {
        let highlight = site.highlight.map { "\($0.lowerBound)-\($0.upperBound)" } ?? "caret"
        return "\(site.registration.applicationID)|\(site.relativePath)|\(site.caret)|\(highlight)"
    }
}
