//
//  InferenceUnitAnnotator.swift
//  MaryBrain
//
//  Turns a unit's structure into one sentence about what it is for, plus the
//  concept labels that let a code neighbourhood be reached from an unrelated
//  domain. The labels are the whole reason this step exists: "ordering",
//  "arbitration", "back-pressure" are what let a file in a Swift project and a
//  chapter in a manuscript land near each other, which identifiers never would.
//
//  TWO RULES, BOTH ABOUT NOT STEALING THE TURN PATH.
//
//  1. IT REFUSES ON AN EXCLUSIVE ENGINE. `requiresExclusiveGeneration` is true
//     only for the on-device MLX engine, and the brain serializes generation
//     rounds across lanes when it is set. A background annotator queuing behind
//     that gate is precisely the latency regression this codebase already fixed
//     once: work waiting on the gate ate the join grace, so fast actions
//     detached as routines and every detach begat another. Refusing is not a
//     degradation to apologize for — the unit still deposits with its structure
//     and headers, which is most of the value.
//
//  2. IT NEVER SEES A FILE. `UnitAnnotationRequest` carries declarations,
//     headers, and the author's own doc comment; nothing upstream of it ever
//     holds a function body, so nothing here can leak one.
//
//  Failures are silent and total: a nil annotation is an ordinary outcome, not
//  an error worth a spoken word.
//

import MaryAmbient
import Foundation
import os

public actor InferenceUnitAnnotator: UnitAnnotating {

    /// Generous — this is background work with no one waiting — but finite, so
    /// a wedged endpoint cannot pin the annotation chain forever.
    public static let timeoutNanoseconds: UInt64 = 45_000_000_000
    /// Labels past this are dropped. A file that "expresses" fifteen concepts
    /// expresses none of them.
    public static let maximumLabels = 5
    public static let maximumPrecisLength = 240

    private let engine: any InferenceEngine
    private static let log = Logger(subsystem: "nyc.rao.mary", category: "unit-index")

    public init(engine: any InferenceEngine) {
        self.engine = engine
    }

    /// Declines by POLICY, not by failure, when the engine is the on-device
    /// one — so the coordinator can record "structure only, on purpose"
    /// rather than "the summariser returned nothing", which is a different
    /// and much more alarming thing to read.
    ///
    /// `nonisolated` because it reads a `let` and the coordinator asks
    /// synchronously; there is nothing to race.
    public nonisolated var refusesToAnnotate: Bool {
        engine.requiresExclusiveGeneration
    }

    public func annotate(_ request: UnitAnnotationRequest) async -> UnitAnnotation? {
        guard !engine.requiresExclusiveGeneration else {
            Self.log.debug("annotation skipped: engine requires exclusive generation")
            return nil
        }
        guard let raw = await complete(prompt: Self.prompt(for: request)) else { return nil }
        return Self.parse(raw)
    }

    // MARK: - The round

    private func complete(prompt: String) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask { [engine] in
                var text = ""
                do {
                    for try await event in engine.stream(
                        system: Self.systemPrompt, history: [.init(role: .user, text: prompt)],
                        skills: []
                    ) {
                        switch event {
                        case .text(let chunk): text += chunk
                        case .skillInvocation: continue
                        case .done: break
                        }
                    }
                } catch {
                    return text.isEmpty ? nil : text
                }
                return text.isEmpty ? nil : text
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: Self.timeoutNanoseconds)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: - Prompt

    static let systemPrompt = """
        You describe one source file for a personal code index. Answer with \
        JSON only, no prose around it, in exactly this shape:

        {"precis": "one sentence", "labels": ["concept", "concept"]}

        The precis says what this file is FOR in one plain sentence — its role, \
        not a list of its contents. The labels are two to five short conceptual \
        tags naming the PATTERN at work (for example: ordering, arbitration, \
        back-pressure, caching, attention-budgeting, state-machine). Use \
        lowercase hyphenated words. Choose labels a person could recognise in \
        an entirely different kind of work, not names taken from this code.
        """

    static func prompt(for request: UnitAnnotationRequest) -> String {
        var lines = [
            "Project: \(request.projectName)",
            "File: \(request.relativePath)",
        ]
        if !request.declaredTypes.isEmpty {
            lines.append("Declares: \(request.declaredTypes.joined(separator: ", "))")
        }
        let inherited = request.relations
            .filter { $0.predicate == .inheritsFrom }
            .map { "\($0.subject) inherits from \($0.object)" }
        if !inherited.isEmpty {
            lines.append(contentsOf: inherited)
        }
        let held = request.relations.filter { $0.predicate == .holds }.map(\.object)
        if !held.isEmpty {
            lines.append("Holds: \(held.joined(separator: ", "))")
        }
        if let doc = request.doc, !doc.isEmpty {
            lines.append("The author's own description: \(doc)")
        }
        if !request.apiHeaders.isEmpty {
            lines.append("Public API:")
            lines.append(contentsOf: request.apiHeaders.prefix(20).map { "  \($0)" })
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Parsing

    /// Tolerant on the way in, strict on the way out. A model that wraps its
    /// JSON in a fence or a sentence still parses; anything that does not
    /// yield both a précis and at least one label is nil, because a
    /// half-annotation is worse than an honest structural card.
    static func parse(_ raw: String) -> UnitAnnotation? {
        guard let data = jsonObject(in: raw),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let precis = (object["precis"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let labels = (object["labels"] as? [Any])?
            .compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            ?? []

        guard !precis.isEmpty, !labels.isEmpty else { return nil }
        return UnitAnnotation(
            precis: precis.count > maximumPrecisLength
                ? String(precis.prefix(maximumPrecisLength)) + "…"
                : precis,
            labels: Array(labels.prefix(maximumLabels)))
    }

    /// The outermost `{…}` in the text, so a fenced or prefaced answer still
    /// reads. Brace-counting rather than a regex, since a label could contain
    /// one.
    private static func jsonObject(in raw: String) -> Data? {
        guard let start = raw.firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = start
        while index < raw.endIndex {
            if raw[index] == "{" { depth += 1 }
            if raw[index] == "}" {
                depth -= 1
                if depth == 0 {
                    return String(raw[start...index]).data(using: .utf8)
                }
            }
            index = raw.index(after: index)
        }
        return nil
    }
}
