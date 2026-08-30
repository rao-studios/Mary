//
//  SeerWire.swift
//  MaryBrain
//
//  Wire types for the local Seer server's HTTP API — auth and chat
//  completions. Mirrors Sis's Requests.Auth/Requests.Chat shapes (snake_case
//  keys, tolerant chunk decode). Verified live against the local server:
//  SSE frames are whole-JSON `data: {…}` lines; the contribution rides a
//  TRAILING chunk with empty `choices`; `data: [DONE]` terminates.
//

import Foundation
import MaryPlugin

enum SeerWire {

    // MARK: - Auth

    struct SignInRequest: Encodable {
        var email: String
        var password: String
    }

    struct RefreshRequest: Encodable {
        var refreshToken: String

        enum CodingKeys: String, CodingKey {
            case refreshToken = "refresh_token"
        }
    }

    struct SessionResponse: Decodable {
        var accessToken: String
        var refreshToken: String
        var expiresIn: Double
        var userID: String

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case userID = "user_id"
        }
    }

    // MARK: - Chat request

    struct ChatRequest: Encodable {
        var messages: [SeerChatMessage]
        /// nil = Seer's default chat model (Inkling). A per-install override
        /// is the user's lever on thinking-model TTFT.
        var model: String?
        var maxTokens = 1200
        var temperature = 0.4
        var topP = 0.9
        var stream = true
        var stop = ["###", "END"]
        var repetitionPenalty = 1.1
        var repetitionContextSize = 20
        var instructions: String?
        /// Identifies Mary to Seer: the server switches retrieved context to
        /// SUPPORT framing (background for the current request, Skill deposits
        /// on their own tier) instead of primary conversational material.
        /// Rides both transports — the realtime turn.start wraps this same
        /// request. Old servers ignore the unknown key.
        var client = "mary"
        /// Who she is on this request. Seer's prompt otherwise says
        /// "Your name is Seer". Rides both transports — the realtime
        /// turn.start wraps this same request.
        var persona = Persona.mary
        var seer: SeerScope

        enum CodingKeys: String, CodingKey {
            case messages, model, temperature, stream, stop, instructions, seer, client, persona
            case maxTokens = "max_tokens"
            case topP = "top_p"
            case repetitionPenalty = "repetition_penalty"
            case repetitionContextSize = "repetition_context_size"
        }
    }

    /// Mary's identity for Seer's personality section — the only place the
    /// voice lane states who she is. Clock and TTS stay on `seerPreamble`;
    /// repeating this in `instructions` made Seer wrap "Your name is Mary"
    /// around a second "You are Mary".
    struct Persona: Encodable, Equatable {
        var name: String
        var voice: String

        static let mary = Persona(
            name: "Mary",
            voice: """
            You are Mary — that is your name; always identify as Mary, never \
            any other assistant name. You are a voice assistant living on the \
            user's Mac: a warm, knowledgeable sibling who ACTS — not a \
            read-only chat.
            """
        )
    }

    /// The `seer` object steering RAG. `owner_id` is overridden server-side
    /// by the JWT for non-admin routes; sent anyway to match Sis.
    ///
    /// `groups` + `aggregate` are the whole of client-side scoping, and the
    /// server already honors both — matched field-for-field against
    /// `SeerRequest` (seer-server `Sources/Core/Models/Seer.Request.swift`):
    /// *"Multi-group filter for chat completions. When non-nil and non-empty,
    /// HNSW search is restricted to documents belonging to any of these
    /// groups"* and *"aggregate == true → search all of the owner's documents
    /// (across all groups); false → search only the group provided"*.
    /// `Seer+TotemFanout` reads `request.groups?.map(\.id)` into the Totem
    /// search request, so only `id` is load-bearing — but the whole object
    /// must still DECODE, which is why `groups` is `[SeerGroupRef]` and not
    /// `[String]`: `SeerRequest.init(from:)` does
    /// `decodeIfPresent([Seer.Group].self, forKey: .groups)`, and a type
    /// mismatch there throws and fails the ENTIRE request rather than
    /// degrading. Unknown keys are still ignored by old servers (the standing
    /// precedent for `client` above); a wrongly-TYPED known key is not.
    struct SeerScope: Encodable {
        var ownerID: String
        var scope = "personal"
        /// Was hardcoded `true`. Kept as the default so an unscoped turn is
        /// byte-identical to before; a focused document flips it to false so
        /// retrieval cannot reach outside that document's group — including
        /// the legacy owner-wide pool, which is where the deleted paragraph
        /// lived.
        var aggregate = true
        /// Nil-omitted; nil = no group filter (today's shape exactly).
        var groups: [SeerGroupRef]?
        var entities: [String]? = nil
        var personalTotemID: String?
        var requestID: String

        enum CodingKeys: String, CodingKey {
            case scope, aggregate, groups, entities
            case ownerID = "owner_id"
            case personalTotemID = "personal_totem_id"
            case requestID = "request_id"
        }
    }

    /// The minimum `Seer.Group` the server will decode: `id`, `label` and
    /// `owner_id` are `decode` (required); `documents`, `access`,
    /// `total_earnings` and `metadata` are all `decodeIfPresent`, so they are
    /// omitted here rather than faked.
    struct SeerGroupRef: Encodable, Equatable {
        var id: String
        var label: String
        var ownerID: String

        enum CodingKeys: String, CodingKey {
            case id, label
            case ownerID = "owner_id"
        }
    }

    // MARK: - Scope construction

    /// ONE builder for BOTH transports. The realtime route wraps the
    /// identical `ChatRequest`, so a scope applied to the SSE lane alone
    /// would present as "scoping works until I switch transports in
    /// Settings" — a bug with no visible cause. Neither client is allowed to
    /// spell a `SeerScope` itself.
    static func scope(
        ownerID: String,
        personalTotemID: String?,
        retrieval: RetrievalScope
    ) -> SeerScope {
        SeerScope(
            ownerID: ownerID,
            aggregate: retrieval.aggregate,
            groups: retrieval.groups.isEmpty ? nil : retrieval.groups.map {
                SeerGroupRef(id: $0.id, label: $0.label, ownerID: ownerID)
            },
            entities: retrieval.relationshipHints.isEmpty ? nil : retrieval.relationshipHints,
            personalTotemID: personalTotemID,
            requestID: UUID().uuidString.lowercased()
        )
    }

    // MARK: - Chat stream chunk

    struct StreamChunk: Decodable {
        var choices: [StreamChoice]
        var contribution: SeerContribution?
        var autoMemory: Bool

        enum CodingKeys: String, CodingKey {
            case choices, contribution
            case autoMemory = "auto_memory"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            choices = try container.decodeIfPresent([StreamChoice].self, forKey: .choices) ?? []
            contribution = try container.decodeIfPresent(SeerContribution.self, forKey: .contribution)
            autoMemory = try container.decodeIfPresent(Bool.self, forKey: .autoMemory) ?? false
        }
    }

    struct StreamChoice: Decodable {
        var delta: Delta

        enum CodingKeys: String, CodingKey {
            case delta
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            delta = try container.decodeIfPresent(Delta.self, forKey: .delta) ?? Delta()
        }
    }

    struct Delta: Decodable {
        var role: String?
        var content: String?

        init(role: String? = nil, content: String? = nil) {
            self.role = role
            self.content = content
        }
    }

    // MARK: - Vision look

    /// Mirrors Seer's `VisionLookRequest` (Sources/API/Routes/VisionLook.swift):
    /// one ephemeral image, base64 in JSON, described in one bounded answer.
    struct VisionLookRequest: Encodable {
        var image: String
        var mediaType: String
        var mode: String
        var pageTitle: String?
        var pageText: String?
        var direction: String?

        enum CodingKeys: String, CodingKey {
            case image, mode, direction
            case mediaType = "media_type"
            case pageTitle = "page_title"
            case pageText = "page_text"
        }
    }

    struct VisionLookResponse: Decodable {
        var text: String
    }

    // MARK: - Complete

    /// Mirrors Seer's `CompleteRequest` (Sources/API/Routes/Complete.swift):
    /// one bounded generation, no `seer` scope, no streaming.
    struct CompleteRequest: Encodable {
        var instructions: String?
        var messages: [SeerChatMessage]
        var maxTokens: Int?
        var temperature: Float?

        enum CodingKeys: String, CodingKey {
            case instructions, messages, temperature
            case maxTokens = "max_tokens"
        }
    }

    struct CompleteResponse: Decodable {
        var text: String

        enum CodingKeys: String, CodingKey {
            case text, output, completion, content, choices
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            if let text = Self.firstNonEmpty(
                try values.decodeIfPresent(String.self, forKey: .text),
                try values.decodeIfPresent(String.self, forKey: .output),
                try values.decodeIfPresent(String.self, forKey: .completion),
                try values.decodeIfPresent(String.self, forKey: .content)
            ) {
                self.text = text
                return
            }
            if let choices = try values.decodeIfPresent([Choice].self, forKey: .choices),
               let text = choices.lazy.compactMap(\.text).first(where: { !$0.isEmpty }) {
                self.text = text
                return
            }
            self.text = ""
        }

        private struct Choice: Decodable {
            var text: String?

            enum CodingKeys: String, CodingKey {
                case text, message
            }

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                if let text = try values.decodeIfPresent(String.self, forKey: .text),
                   !text.isEmpty {
                    self.text = text
                    return
                }
                if let message = try values.decodeIfPresent(Message.self, forKey: .message),
                   let content = message.content, !content.isEmpty {
                    self.text = content
                    return
                }
                self.text = nil
            }

            struct Message: Decodable {
                var content: String?
            }
        }

        private static func firstNonEmpty(_ candidates: String?...) -> String? {
            for candidate in candidates {
                let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !value.isEmpty { return value }
            }
            return nil
        }
    }

    // MARK: - Skills complete

    /// Mirrors Seer's `SkillsCompleteRequest` — one bounded generation with
    /// a tool roster, no `seer` scope, no streaming, roles preserved.
    struct SkillsCompleteRequest: Encodable {
        var instructions: String?
        var messages: [SeerChatMessage]
        var tools: [SkillTool]?
        var maxTokens: Int?
        var temperature: Float?

        enum CodingKeys: String, CodingKey {
            case instructions, messages, tools, temperature
            case maxTokens = "max_tokens"
        }
    }

    struct SkillTool: Encodable {
        var type = "function"
        var function: SkillFunction

        static func from(_ schema: ModelSkillSchema) -> SkillTool {
            var properties: [String: SkillProperty] = [:]
            var required: [String] = []
            for parameter in schema.parameters {
                properties[parameter.name] = SkillProperty(
                    type: parameter.type,
                    description: parameter.description,
                    enumValues: parameter.enumValues,
                    minimum: parameter.minimum,
                    maximum: parameter.maximum)
                if parameter.required { required.append(parameter.name) }
            }
            return SkillTool(function: SkillFunction(
                name: schema.name,
                description: schema.description,
                parameters: SkillParameters(properties: properties, required: required)))
        }
    }

    struct SkillFunction: Encodable {
        var name: String
        var description: String
        var parameters: SkillParameters
    }

    struct SkillParameters: Encodable {
        var type = "object"
        var properties: [String: SkillProperty]
        var required: [String]
    }

    struct SkillProperty: Encodable {
        var type: String
        var description: String
        var enumValues: [String]?
        var minimum: Double?
        var maximum: Double?

        enum CodingKeys: String, CodingKey {
            case type, description, minimum, maximum
            case enumValues = "enum"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(type, forKey: .type)
            try container.encode(description, forKey: .description)
            if let enumValues { try container.encode(enumValues, forKey: .enumValues) }
            if let minimum { try container.encode(minimum, forKey: .minimum) }
            if let maximum { try container.encode(maximum, forKey: .maximum) }
        }
    }

    struct SkillsCompleteResponse: Decodable {
        var text: String
        var toolCalls: [SkillToolCall]

        enum CodingKeys: String, CodingKey {
            case text, toolCalls = "tool_calls"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            text = try values.decodeIfPresent(String.self, forKey: .text) ?? ""
            toolCalls = try values.decodeIfPresent([SkillToolCall].self, forKey: .toolCalls) ?? []
        }
    }

    struct SkillToolCall: Decodable {
        var name: String
        var arguments: String

        enum CodingKeys: String, CodingKey {
            case name, arguments
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            name = try values.decode(String.self, forKey: .name)
            if let text = try? values.decode(String.self, forKey: .arguments) {
                arguments = text
            } else if let object = try? values.decode([String: SeerJSONValue].self, forKey: .arguments),
                      let data = try? JSONEncoder().encode(object),
                      let text = String(data: data, encoding: .utf8) {
                arguments = text
            } else {
                arguments = "{}"
            }
        }
    }

    /// Tiny JSON tree so tool-call `arguments` may arrive as an object.
    enum SeerJSONValue: Codable {
        case string(String)
        case number(Double)
        case bool(Bool)
        case object([String: SeerJSONValue])
        case array([SeerJSONValue])
        case null

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let b = try? c.decode(Bool.self) { self = .bool(b) }
            else if let n = try? c.decode(Double.self) { self = .number(n) }
            else if let s = try? c.decode(String.self) { self = .string(s) }
            else if let a = try? c.decode([SeerJSONValue].self) { self = .array(a) }
            else if let o = try? c.decode([String: SeerJSONValue].self) { self = .object(o) }
            else {
                throw DecodingError.typeMismatch(
                    SeerJSONValue.self,
                    .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON"))
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .string(let s): try c.encode(s)
            case .number(let n): try c.encode(n)
            case .bool(let b): try c.encode(b)
            case .object(let o): try c.encode(o)
            case .array(let a): try c.encode(a)
            case .null: try c.encodeNil()
            }
        }
    }
}
