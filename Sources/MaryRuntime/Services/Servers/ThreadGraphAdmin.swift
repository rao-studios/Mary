//
//  ThreadGraphAdmin.swift
//  MaryRuntime
//
//  WHAT: Irreversible graph surgery over Thread HTTP (rename/merge/delete/re-kind).
//  OUT:  MutationResult — callers re-query; do not trust response shape
//  PIN:  UI must confirm. Routes/keys mirror Thread GraphAdmin. Re-extract
//        gets a long deadline; row edits keep the 5s ThreadGraphPolicy budget.
//

import Foundation

/// Graph mutation verdict. success:false + 200 = missing id (data, not transport).
package struct MutationResult: Equatable, Sendable {
    package var success: Bool
    package var survivingID: String?
    package var entityCount: Int?

    package init(success: Bool, survivingID: String? = nil, entityCount: Int? = nil) {
        self.success = success
        self.survivingID = survivingID
        self.entityCount = entityCount
    }
}

package enum ThreadGraphAdmin {

    /// Transport reached the server but the exchange still failed. Transport
    /// errors themselves (connection refused, timeout) propagate as URLError.
    enum AdminError: Error, LocalizedError {
        case badURL
        case httpStatus(Int, serverMessage: String?)
        case undecodableResponse

        var errorDescription: String? {
            switch self {
            case .badURL:
                return "Could not form the Thread admin URL."
            case .httpStatus(let code, let message):
                if let message, !message.isEmpty {
                    return "Thread refused the mutation (HTTP \(code)): \(message)"
                }
                return "Thread refused the mutation (HTTP \(code))."
            case .undecodableResponse:
                return "Thread answered the mutation with an unreadable body."
            }
        }
    }

    // MARK: - Entity mutations

    package static func renameEntity(id: String, name: String, port: Int) async throws -> MutationResult {
        try await post("/v1/graph/entity/rename", body: ["id": id, "name": name], port: port)
    }

    package static func mergeEntities(from: String, into: String, port: Int) async throws -> MutationResult {
        try await post("/v1/graph/entity/merge", body: ["from": from, "into": into], port: port)
    }

    package static func deleteEntity(id: String, port: Int) async throws -> MutationResult {
        try await post("/v1/graph/entity/delete", body: ["id": id], port: port)
    }

    package static func setEntityKind(id: String, kind: String, port: Int) async throws -> MutationResult {
        try await post("/v1/graph/entity/set-kind", body: ["id": id, "kind": kind], port: port)
    }

    // MARK: - Relationship mutation

    package static func deleteRelationship(id: String, port: Int) async throws -> MutationResult {
        try await post("/v1/graph/relationship/delete", body: ["id": id], port: port)
    }

    // MARK: - Re-extraction

    /// Re-extract: long timeout for the synchronous LLM route. ownerID in nested thread envelope.
    package static func reextractDocument(documentID: String, ownerID: String, port: Int) async throws -> MutationResult {
        try await post(
            "/v1/graph/re-extract",
            body: ["document_id": documentID, "thread": ["owner_id": ownerID]],
            port: port,
            timeout: 120
        )
    }

    // MARK: - Wire

    /// snake_case is the server's contract (GraphMutationResponse); decoded
    /// here once so MutationResult stays a plain app-side value.
    private struct WireResponse: Decodable {
        package let success: Bool
        let survivingId: String?
        package let entityCount: Int?

        enum CodingKeys: String, CodingKey {
            case success
            case survivingId = "surviving_id"
            case entityCount = "entity_count"
        }
    }

    private static func post(
        _ path: String,
        body: [String: Any],
        port: Int,
        timeout: TimeInterval = 5
    ) async throws -> MutationResult {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else {
            throw AdminError.badURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else {
            throw AdminError.undecodableResponse
        }
        guard status == 200 else {
            // Hummingbird error bodies are not a stable shape — surface the
            // raw text so a badRequest's message reaches the dialog, capped so
            // an HTML error page cannot flood an alert.
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(300)
            throw AdminError.httpStatus(status, serverMessage: message.map(String.init))
        }
        guard let wire = try? JSONDecoder().decode(WireResponse.self, from: data) else {
            throw AdminError.undecodableResponse
        }
        return MutationResult(
            success: wire.success,
            survivingID: wire.survivingId,
            entityCount: wire.entityCount
        )
    }
}
