//
//  UnitAnnotationPrompt.swift
//  MaryBrain
//
//  WHAT: The prompt a corpus unit is described with, and the strict parse of
//        the answer. No engine — annotation runs through Seer's /v1/complete.
//  IN:   SeerUnitAnnotator
//  OUT:  UnitAnnotation
//  PIN:  Was InferenceUnitAnnotator's statics, which also held an on-device
//        engine that always refused. The prompt outlived the engine.
//
import MaryAmbient
import Foundation

public enum UnitAnnotationPrompt {

    /// Labels past this are dropped. A file that "expresses" fifteen concepts
    /// expresses none of them.
    public static let maximumLabels = 5
    public static let maximumPrecisLength = 240

    // MARK: - Prompt

    public static let systemPrompt = """
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

    public static func prompt(for request: UnitAnnotationRequest) -> String {
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

    /// Tolerant on the way in, strict on the way out.
    public static func parse(_ raw: String) -> UnitAnnotation? {
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
