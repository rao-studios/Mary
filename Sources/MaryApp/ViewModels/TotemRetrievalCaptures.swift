//
//  TotemRetrievalCaptures.swift
//
//  Split out of TotemExplorerViewModel.swift (docs/DECOMPOSITION.md
//  Wave 2) — pure relocation, no declaration changed.
//

import MaryAmbient
import MaryBrain
import MaryFoundation
import MaryTotem
import Foundation
import SwiftUI

// MARK: - Retrieval captures (input side)

/// App-side mirror of `SeerRequestTrace`. It exists because the MaryBrain
/// trace types are projection-only BY DESIGN — their inits are the redaction
/// seam — so the app cannot construct fixtures of them, and an untestable
/// `build` would defeat the pure core. `gather()` projects the ledger's rows
/// through these; tests construct them directly.
struct TotemSeerRequestCapture: Equatable {
    var id: String
    var sentAt: Date
    var transport: SeerTransportKind
    var ownerID: String
    var aggregate: Bool
    var groups: [RetrievalScope.Group]
    var relationshipHints: [String]
    var personalTotemID: String?

    init(
        id: String,
        sentAt: Date,
        transport: SeerTransportKind,
        ownerID: String,
        aggregate: Bool,
        groups: [RetrievalScope.Group],
        relationshipHints: [String] = [],
        personalTotemID: String? = nil
    ) {
        self.id = id
        self.sentAt = sentAt
        self.transport = transport
        self.ownerID = ownerID
        self.aggregate = aggregate
        self.groups = groups
        self.relationshipHints = relationshipHints
        self.personalTotemID = personalTotemID
    }

    init(_ trace: SeerRequestTrace) {
        self.init(
            id: trace.id,
            sentAt: trace.sentAt,
            transport: trace.transport,
            ownerID: trace.ownerID,
            aggregate: trace.aggregate,
            groups: trace.groups,
            relationshipHints: trace.relationshipHints,
            personalTotemID: trace.personalTotemID)
    }
}

/// App-side mirror of `RetrievalTraceRecord` — same reason as its request
/// sibling above.
struct TotemRetrievalCapture: Equatable {
    var id: UUID
    var exchangeID: UUID
    var routeTraceID: UUID?
    var date: Date
    var requests: [TotemSeerRequestCapture]
    var contribution: SeerContributionTrace?
    var contributionRequestID: String?
    var ambient: [AmbientInjectionTrace]
    var promptSpend: [PromptSpendTrace]

    init(
        id: UUID = UUID(),
        exchangeID: UUID,
        routeTraceID: UUID? = nil,
        date: Date,
        requests: [TotemSeerRequestCapture] = [],
        contribution: SeerContributionTrace? = nil,
        contributionRequestID: String? = nil,
        ambient: [AmbientInjectionTrace] = [],
        promptSpend: [PromptSpendTrace] = []
    ) {
        self.id = id
        self.exchangeID = exchangeID
        self.routeTraceID = routeTraceID
        self.date = date
        self.requests = requests
        self.contribution = contribution
        self.contributionRequestID = contributionRequestID
        self.ambient = ambient
        self.promptSpend = promptSpend
    }

    init(record: RetrievalTraceRecord) {
        self.init(
            id: record.id,
            exchangeID: record.exchangeID,
            routeTraceID: record.routeTraceID,
            date: record.date,
            requests: record.requests.map(TotemSeerRequestCapture.init),
            contribution: record.contribution,
            contributionRequestID: record.contributionRequestID,
            ambient: record.ambient,
            promptSpend: record.promptSpend)
    }
}
