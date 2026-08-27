//
//  TotemGraphPolicy.swift
//  Mary
//
//  Mary's managed additions to Totem's graph-extraction policy: the custom
//  ontology kinds its deposits use (so the server-side LLM extractor speaks
//  the same vocabulary) and co-mention auto-edges (so ambient documents
//  self-link their cast). Pushed as GET → merge → PUT over Totem's HTTP port
//  — raw JSON merge, so unknown policy fields survive untouched and the push
//  is idempotent. Prospective-only: existing docs pick changes up on
//  re-extraction, which is fine for a policy that mostly shapes new deposits.
//

import Foundation

package enum TotemGraphPolicy {

    /// name → prompt description, matching ContextEntityComposer.customKinds.
    package static let maryKinds: [(name: String, description: String)] = [
        ("file", "a source or document file, named by its project-relative path"),
        ("document", "a prose document the user writes in, named as they name it"),
        ("project", "a software project or repository"),
        ("app", "an application on the user's computer"),
        ("ability-package", "a portable Mary Ability package with a stable version"),
        ("ability", "a Mary Ability that organizes machine-level Skills"),
        ("skill", "a machine-level Skill invoked through a Mary Ability"),
        ("type", "a type declared in the user's own code, named as they named it"),
    ]

    /// Merge Mary's kinds + enable co-mention edges. Returns true when the
    /// PUT succeeded; failures are boot-tolerable (log-and-continue).
    package static func push(totemPort: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(totemPort)/v1/graph/policy") else {
            return false
        }
        var getRequest = URLRequest(url: url)
        getRequest.timeoutInterval = 5
        guard let (data, response) = try? await URLSession.shared.data(for: getRequest),
              (response as? HTTPURLResponse)?.statusCode == 200,
              var policy = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return false
        }

        var kinds = policy["kinds"] as? [[String: Any]] ?? []
        let existing = Set(kinds.compactMap { $0["name"] as? String })
        var changed = false
        for kind in maryKinds where !existing.contains(kind.name) {
            kinds.append(["name": kind.name, "description": kind.description])
            changed = true
        }
        policy["kinds"] = kinds

        var coMention = policy["co_mention"] as? [String: Any] ?? [:]
        if (coMention["enabled"] as? Bool) != true {
            coMention["enabled"] = true
            policy["co_mention"] = coMention
            changed = true
        }

        guard changed else { return true }   // already in place — idempotent

        var putRequest = URLRequest(url: url)
        putRequest.httpMethod = "PUT"
        putRequest.timeoutInterval = 5
        putRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        putRequest.httpBody = try? JSONSerialization.data(withJSONObject: policy)
        guard let (_, putResponse) = try? await URLSession.shared.data(for: putRequest) else {
            return false
        }
        return (putResponse as? HTTPURLResponse)?.statusCode == 200
    }
}
