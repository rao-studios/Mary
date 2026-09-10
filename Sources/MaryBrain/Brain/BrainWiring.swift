//
//  BrainWiring.swift
//  MaryBrain
//
//  WHAT: Brain's cross-cutting stores, named in one place.
//  IN:   composition root (process-wide) or defaults
//  OUT:  ledger / ambient / focus / assembler
//  PIN:  Defaults are fresh, never `.shared`.
//
import MaryAmbient
import Foundation

/// The brain's cross-cutting stores. See the header: default-fresh, root-
/// injected, defaults transitional.
public struct BrainWiring: Sendable {
    public var retrieval: RetrievalTraceLedger
    public var containers: ContainerRegistry
    public var focusTracker: WorkspaceFocusTracker
    public var readLedger: ReadDeliveryLedger
    public var world: AmbientWorld
    public var elementIndex: AmbientElementIndexStore
    /// WHAT MARY DID, one episode per user turn. Default-fresh like the rest
    public var behavior: BehavioralAssembler

    public init(
        retrieval: RetrievalTraceLedger = RetrievalTraceLedger(),
        containers: ContainerRegistry = ContainerRegistry(),
        focusTracker: WorkspaceFocusTracker = WorkspaceFocusTracker(),
        readLedger: ReadDeliveryLedger = ReadDeliveryLedger(),
        world: AmbientWorld = AmbientWorld(),
        elementIndex: AmbientElementIndexStore = AmbientElementIndexStore(),
        behavior: BehavioralAssembler = BehavioralAssembler(),
    ) {
        self.retrieval = retrieval
        self.containers = containers
        self.focusTracker = focusTracker
        self.readLedger = readLedger
        self.world = world
        self.elementIndex = elementIndex
        self.behavior = behavior
        // The ledger is composed OVER the element index (the same coupling
        // the production singleton declares), so an explicit index flows into
        // a defaulted ledger rather than the two silently diverging.
    }
}
