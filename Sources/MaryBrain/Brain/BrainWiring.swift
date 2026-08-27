//
//  BrainWiring.swift
//  MaryBrain
//
//  THE BRAIN'S CROSS-CUTTING STORES, named in one place — the ownership
//  program's Stage-0 seam (docs/ownership/STAGE-0-entry-gate.md, Step 3).
//
//  Transitional defaults construct FRESH instances — never `.shared` — so an
//  uninjected brain is isolated by construction: two brains built side by
//  side in one test process cannot write into each other's ledgers, which is
//  the shared-state half of the suite's old parallel-vs-serial divergence.
//  The composition root passes its own (the process-wide singletons, made
//  explicit and greppable). The defaults are deleted in Stage 8.
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
    public var ambient: AmbientContextStore
    public var elementIndex: AmbientElementIndexStore
    /// WHAT MARY DID, one episode per user turn. Default-fresh like the rest,
    /// and default-recorderless: an assembler with nowhere to seal is a
    /// working assembler that writes nothing, which is exactly what a test or
    /// a recording-disabled build wants. The composition root passes one with
    /// a store behind it.
    public var behavior: BehavioralAssembler

    public init(
        retrieval: RetrievalTraceLedger = RetrievalTraceLedger(),
        containers: ContainerRegistry = ContainerRegistry(),
        focusTracker: WorkspaceFocusTracker = WorkspaceFocusTracker(),
        readLedger: ReadDeliveryLedger = ReadDeliveryLedger(),
        ambient: AmbientContextStore = AmbientContextStore(),
        elementIndex: AmbientElementIndexStore = AmbientElementIndexStore(),
        behavior: BehavioralAssembler = BehavioralAssembler(),
    ) {
        self.retrieval = retrieval
        self.containers = containers
        self.focusTracker = focusTracker
        self.readLedger = readLedger
        self.ambient = ambient
        self.elementIndex = elementIndex
        self.behavior = behavior
        // The ledger is composed OVER the element index (the same coupling
        // the production singleton declares), so an explicit index flows into
        // a defaulted ledger rather than the two silently diverging.
    }
}
