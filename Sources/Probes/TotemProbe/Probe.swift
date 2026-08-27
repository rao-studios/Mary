//
//  Probe.swift
//  mary-totem-probe
//
//  Headless exerciser for the TotemDirectClient facade against a live local
//  Totem (:9090) — the MaryTotem sibling of `mary-voice-probe`.
//
//    mary-totem-probe deposit "some text" --owner o1 [--doc-id d1] [--group g1]
//                       [--entity name:kind]... [--relation subj:pred:obj]...
//    mary-totem-probe search "query" --owner o1
//    mary-totem-probe library --owner o1
//    mary-totem-probe groups --docs d1,d2 --owner o1
//    mary-totem-probe doc --docs d1,d2 --owner o1   (full content by id)
//    mary-totem-probe stats --owner o1
//    mary-totem-probe remove --docs d1,d2 --owner o1
//    mary-totem-probe roundtrip --owner o1     (deposit → search → fetch → remove)
//

import MaryTotem
import Foundation

struct ProbeArgs {
    var positional: [String] = []
    var options: [String: [String]] = [:]

    init(_ arguments: [String]) {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--") {
                let key = String(argument.dropFirst(2))
                if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                    options[key, default: []].append(arguments[index + 1])
                    index += 2
                } else {
                    options[key, default: []].append("")
                    index += 1
                }
            } else {
                positional.append(argument)
                index += 1
            }
        }
    }

    func option(_ key: String) -> String? { options[key]?.last }
    func all(_ key: String) -> [String] { options[key] ?? [] }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}

func parseEntities(_ raw: [String]) -> [TotemEntityIn] {
    raw.compactMap { spec in
        let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
        guard let name = parts.first, !name.isEmpty else { return nil }
        return TotemEntityIn(name: name, kind: parts.count > 1 ? parts[1] : "concept")
    }
}

func parseRelations(_ raw: [String]) -> [TotemRelationIn] {
    raw.compactMap { spec in
        let parts = spec.split(separator: ":").map(String.init)
        guard parts.count == 3 else { return nil }
        return TotemRelationIn(subject: parts[0], predicate: parts[1], object: parts[2])
    }
}

@main
enum Probe {
    static func main() async {
        let rawArguments = Array(CommandLine.arguments.dropFirst())
        guard let command = rawArguments.first else {
            fail("usage: mary-totem-probe <deposit|search|library|groups|stats|remove|roundtrip> …")
        }
        let args = ProbeArgs(Array(rawArguments.dropFirst()))
        let owner = args.option("owner") ?? "mary-probe"
        let host = args.option("host") ?? "127.0.0.1"
        let port = Int(args.option("port") ?? "9090") ?? 9090
        let client = TotemDirectClient(host: host, port: port)
        do {
        switch command {
        case "deposit":
            guard let text = args.positional.first else { fail("deposit needs text") }
            let documentID = args.option("doc-id") ?? "mary-probe-\(UUID().uuidString.lowercased())"
            let item = DepositItem(
                documentID: documentID,
                texts: [text],
                tags: ["mary"],
                name: args.option("name") ?? "probe deposit",
                entities: parseEntities(args.all("entity")),
                relationships: parseRelations(args.all("relation"))
            )
            let count = try await client.deposit(
                [item], ownerID: owner,
                groupID: args.option("group") ?? "mary-context-\(owner)",
                groupLabel: "Mary Context")
            print("deposited \(count) — document_id=\(documentID)")

        case "search":
            guard let query = args.positional.first else { fail("search needs a query") }
            let hits = try await client.search(query: query, ownerID: owner)
            print("\(hits.count) hit(s)")
            for hit in hits {
                let preview = hit.text.prefix(90).replacingOccurrences(of: "\n", with: " ")
                print(String(format: "  %.3f  %@  %@", hit.score, hit.documentID, preview))
            }

        case "library":
            let page = try await client.library(ownerID: owner)
            print("\(page.groups.count) group(s), hasMore=\(page.hasMore)")
            for group in page.groups {
                print("  [\(group.id)] \(group.label) — \(group.documents.count) doc(s)")
            }

        case "groups":
            let ids = (args.option("docs") ?? "").split(separator: ",").map(String.init)
            guard !ids.isEmpty else { fail("groups needs --docs d1,d2") }
            let groups = try await client.groups(containing: ids, ownerID: owner)
            for group in groups {
                print("  [\(group.id)] \(group.label) — docs: \(group.documents.map(\.id).joined(separator: ","))")
            }

        case "doc":
            let ids = (args.option("docs") ?? "").split(separator: ",").map(String.init)
            guard !ids.isEmpty else { fail("doc needs --docs d1,d2") }
            let started = Date()
            let contents = try await client.documents(ids: ids, ownerID: owner)
            let elapsed = Date().timeIntervalSince(started)
            print("\(contents.count) document(s) in \(String(format: "%.0f", elapsed * 1000))ms")
            for document in contents {
                print("── \(document.id)")
                print("   name: \(document.name.isEmpty ? "(unnamed)" : document.name)  group: [\(document.groupID)] \(document.groupLabel)  parts: \(document.texts.count)  bytes: \(document.content.utf8.count)")
                let preview = document.content.prefix(200).replacingOccurrences(of: "\n", with: " ")
                print("   \(preview)")
            }

        case "stats":
            let stats = try await client.graphStats(ownerID: owner)
            print("entities=\(stats.entityCount) relationships=\(stats.relationshipCount)")
            for entity in stats.topEntities {
                print("  \(entity.kind): \(entity.name) (mentions=\(entity.mentionCount))")
            }

        case "remove":
            let ids = (args.option("docs") ?? "").split(separator: ",").map(String.init)
            guard !ids.isEmpty else { fail("remove needs --docs d1,d2") }
            let count = try await client.remove(documentIDs: ids, ownerID: owner)
            print("removed \(count)")

        case "roundtrip":
            let documentID = "mary-probe-roundtrip-\(UUID().uuidString.lowercased())"
            let probeText = "Mary's totem probe verifies the Conduit wire contract end to end."
            let item = DepositItem(
                documentID: documentID,
                texts: [probeText],
                name: "roundtrip probe",
                entities: [
                    TotemEntityIn(name: "mary", kind: "project"),
                    TotemEntityIn(name: "totem probe", kind: "skill"),
                ],
                relationships: [
                    TotemRelationIn(subject: "totem probe", predicate: "verifies", object: "mary")
                ]
            )
            let deposited = try await client.deposit(
                [item], ownerID: owner,
                groupID: "mary-context-\(owner)", groupLabel: "Mary Context")
            print("deposit: indexed_count=\(deposited) document_id=\(documentID)")

            // Index responds before Totem's write queue drains — the doc is
            // searchable only after the batch put commits (~1s coalescing).
            try await Task.sleep(nanoseconds: 3_000_000_000)
            let hits = try await client.search(query: "wire contract probe", ownerID: owner)
            let found = hits.contains { $0.documentID == documentID }
            print("search: \(hits.count) hit(s), roundtrip doc found=\(found)")

            // Content-by-id: the deposited text must come back verbatim.
            let fetched = try await client.documents(ids: [documentID], ownerID: owner)
            let contentOK = fetched.first?.content == probeText
            print("documents: fetched=\(fetched.count) name=\(fetched.first?.name ?? "-") content_matches=\(contentOK)")

            let removed = try await client.remove(documentIDs: [documentID], ownerID: owner)
            print("remove: removed_count=\(removed)")
            if !found || !contentOK || removed != 1 { exit(2) }
            print("ROUNDTRIP OK")

        default:
            fail("unknown command \(command)")
        }
        } catch {
            fail("\(error)")
        }
    }
}
