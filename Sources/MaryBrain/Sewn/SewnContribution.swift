//
//  SewnContribution.swift
//  MaryBrain
//
//  WHAT: Gita contribution metadata on Sewn chat responses.
//  IN:   trailing SSE chunk
//  OUT:  highlight UI (character spans)
//  PIN:  Spans are offsets into the visible string; clamp for graphemes.
//
import Foundation

public struct SewnContribution: Codable, Sendable, Equatable {
    public var owners: Set<Owner>
    public var totalPayout: Double
    public var serviceCharge: Double
    public var totalCost: Double

    public var isAvailable: Bool { !owners.isEmpty }

    /// Owners that credit at least one span of the response text.
    public var spanOwners: [Owner] {
        owners.filter { !$0.spans.isEmpty }.sorted { $0.royalty > $1.royalty }
    }

    enum CodingKeys: String, CodingKey {
        case owners
        case totalPayout = "total_payout"
        case serviceCharge = "service_charge"
        case totalCost = "total_cost"
    }

    public init(
        owners: Set<Owner> = [],
        totalPayout: Double = 0,
        serviceCharge: Double = 0,
        totalCost: Double = 0
    ) {
        self.owners = owners
        self.totalPayout = totalPayout
        self.serviceCharge = serviceCharge
        self.totalCost = totalCost
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        owners = try container.decodeIfPresent(Set<Owner>.self, forKey: .owners) ?? []
        totalPayout = try container.decodeIfPresent(Double.self, forKey: .totalPayout) ?? 0
        serviceCharge = try container.decodeIfPresent(Double.self, forKey: .serviceCharge) ?? 0
        totalCost = try container.decodeIfPresent(Double.self, forKey: .totalCost) ?? 0
    }

    // MARK: - Owner

    public struct Owner: Codable, Sendable, Hashable, Identifiable {
        public var threadID: String
        public var ownerID: String?
        public var documentIDs: Set<String>
        /// documentID → influence weight on the reply.
        public var influence: [String: Double]
        public var royalty: Double
        /// Character spans of the response text credited to this owner.
        public var spans: [TextSpan]
        /// documentID → the spans that document specifically informed.
        public var documentSpans: [String: [TextSpan]]?
        public var earning: Double

        public var id: String { ownerID ?? threadID }

        enum CodingKeys: String, CodingKey {
            case influence, royalty, spans, earning
            case threadID = "thread_id"
            case ownerID = "owner_id"
            case documentIDs = "document_ids"
            case documentSpans = "document_spans"
        }

        public init(
            threadID: String,
            ownerID: String? = nil,
            documentIDs: Set<String> = [],
            influence: [String: Double] = [:],
            royalty: Double = 0,
            spans: [TextSpan] = [],
            documentSpans: [String: [TextSpan]]? = nil,
            earning: Double = 0
        ) {
            self.threadID = threadID
            self.ownerID = ownerID
            self.documentIDs = documentIDs
            self.influence = influence
            self.royalty = royalty
            self.spans = spans
            self.documentSpans = documentSpans
            self.earning = earning
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            threadID = try container.decodeIfPresent(String.self, forKey: .threadID) ?? ""
            ownerID = try container.decodeIfPresent(String.self, forKey: .ownerID)
            documentIDs = try container.decodeIfPresent(Set<String>.self, forKey: .documentIDs) ?? []
            influence = try container.decodeIfPresent([String: Double].self, forKey: .influence) ?? [:]
            royalty = try container.decodeIfPresent(Double.self, forKey: .royalty) ?? 0
            spans = try container.decodeIfPresent([TextSpan].self, forKey: .spans) ?? []
            documentSpans = try container.decodeIfPresent([String: [TextSpan]].self, forKey: .documentSpans)
            earning = try container.decodeIfPresent(Double.self, forKey: .earning) ?? 0
        }

        // Owners are keyed by thread, matching Sis's GitaOwner semantics.
        public func hash(into hasher: inout Hasher) {
            hasher.combine(threadID)
        }

        public static func == (lhs: Owner, rhs: Owner) -> Bool {
            lhs.threadID == rhs.threadID
        }
    }

    // MARK: - TextSpan

    public struct TextSpan: Codable, Sendable, Equatable {
        public var lower: Int
        public var upper: Int

        public init(lower: Int, upper: Int) {
            self.lower = lower
            self.upper = upper
        }

        /// Clamped conversion to a String range; nil when the span is empty,
        /// inverted, or entirely out of bounds.
        public func range(in text: String) -> Range<String.Index>? {
            guard lower >= 0, lower < upper else { return nil }
            guard let start = text.index(text.startIndex, offsetBy: lower, limitedBy: text.endIndex),
                  start < text.endIndex else { return nil }
            let end = text.index(text.startIndex, offsetBy: upper, limitedBy: text.endIndex) ?? text.endIndex
            guard start < end else { return nil }
            return start..<end
        }
    }

    // MARK: - JSON bridging (BrainEvent carries contribution as opaque JSON)

    public var jsonString: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func fromJSON(_ json: String) -> SewnContribution? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SewnContribution.self, from: data)
    }
}
