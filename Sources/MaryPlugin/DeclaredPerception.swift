//
//  DeclaredPerception.swift
//  MaryPlugin
//
//  WHAT: One perception an adapter publishes at the top of a turn.
//  IN:   MaryAdapter.turnPerceptions()
//  OUT:  SchemaSignalRuntime.publishPerception
//  PIN:  THE ADAPTER NAMES ITS OWN SCHEMA, and the runtime asks rather than
//        knowing. What this type deliberately does NOT carry is an adapter id:
//        the publisher stamps the adapter it asked, so a perception can never
//        be attributed to a provider that did not produce it.
//

import Foundation
import MaryFoundation

public struct DeclaredPerception: Sendable {
    /// The perception schema the owning package declares.
    public var schemaID: PerceptionID
    /// The reading, in the schema's own value type.
    public var value: ValueEnvelope

    public init(schemaID: PerceptionID, value: ValueEnvelope) {
        self.schemaID = schemaID
        self.value = value
    }
}
