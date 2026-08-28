//
//  AdapterManifestClaimsTests.swift
//  MaryPluginTests
//
//  EVERY SHIPPED ADAPTER DECLARES ITS OPERATIONS, or this fails.
//
//  THE FAILURE THIS EXISTS TO CATCH has now happened twice, in two codebases,
//  and both times it looked like something else. `MaryAdapter`'s default
//  manifest publishes an operation's NAME and nothing else: no capabilities,
//  no Value types, no target classes. A Skill whose Capability constrains
//  `allowedTargetClass` is then refused at install — an operation claiming no
//  class implements none — so the Skill is published, installed, and
//  unavailable.
//
//  It looked selective both times, which is what made it cost hours rather
//  than minutes. In the media lane four Skills went BLOCKED while
//  `search_music` and `play_music` stayed READY, because their Capabilities
//  constrain no class and the check never ran for them. Two Skills working is
//  a far better disguise for a missing declaration than none working. In the
//  predecessor's Scrivener lane the same shape left four binder ceremonies
//  permanently unreachable, recorded as "phases 2-3 blocked" for weeks.
//
//  SO THE GUARD IS GENERIC AND LIVES HERE, not as a per-adapter test written
//  after each incident. A new adapter that forgets its manifest fails on the
//  build that adds it, which is the only time the fix is cheap.
//
//  WHAT THIS DOES NOT CHECK, deliberately: whether a target class matches the
//  Capability that constrains it. That is a cross-package question — the
//  Capability lives in a `.mary` file — and it belongs to the graph validator
//  and `mary-package-probe`. This checks the half knowable from the adapter
//  alone, which is the half that was missing both times.
//

import MaryFoundation
import XCTest
@testable import MaryPlugin

final class AdapterManifestClaimsTests: XCTestCase {

    private var adapters: [any MaryAdapter] { MaryAdapterCatalog.adapters() }

    /// THE ADAPTERS STILL RIDING THE PROTOCOL'S DEFAULT MANIFEST, recorded
    /// rather than exempted quietly — a pinned set, so the list can shrink
    /// and cannot grow without someone editing this line and reading why.
    ///
    /// Both are safe TODAY and neither is safe by construction. Their Skills
    /// work because no Capability any shipped package declares against them
    /// constrains a target class, so the check that refuses an
    /// under-declared operation never runs. That is the dormant form of the
    /// exact bug above: the first Capability to gain an `allowedTargetClass`
    /// silently blocks them, and the symptom will be one Skill reporting
    /// itself unavailable while its neighbours keep working.
    ///
    /// `prose-surface` additionally publishes three Skills — list_documents,
    /// read_document, create_document — that no shipped package binds at
    /// all; they reach the model directly. Declaring them is worth doing and
    /// belongs with the writing lane rather than smuggled into a browser
    /// change.
    static let ridingTheDefaultManifest: Set<String> = ["applications", "prose-surface"]

    private var declaredAdapters: [any MaryAdapter] {
        adapters.filter { !Self.ridingTheDefaultManifest.contains($0.name) }
    }

    /// The pin itself. A new adapter arriving with no manifest fails here,
    /// which is the point — the default is a shape to leave, not to join.
    func testTheDefaultManifestSetIsExactlyWhatIsRecorded() {
        let riding = Set(
            adapters
                .filter { adapter in
                    adapter.adapterManifest.operations.allSatisfy { operation in
                        operation.capabilities.isEmpty && operation.outputTypes.isEmpty
                            && operation.targetClasses.isEmpty
                    }
                }
                .map(\.name))
        XCTAssertEqual(
            riding, Self.ridingTheDefaultManifest,
            """
            The set of adapters publishing bare operation names has changed. \
            If one gained a manifest, shrink the pin. If a NEW adapter is in \
            here, it needs a manifest before its Skills can be required by \
            any Capability that constrains a target class.
            """)
    }

    // MARK: - The rules, for every adapter that declares

    /// An operation with no capability can satisfy no Skill's requirements.
    /// This is the exact shape the default manifest produces.
    func testEveryDeclaredOperationClaimsAtLeastOneCapability() {
        for adapter in declaredAdapters {
            for operation in adapter.adapterManifest.operations {
                XCTAssertFalse(
                    operation.capabilities.isEmpty,
                    """
                    \(adapter.name).\(operation.operation) claims no capability, \
                    so every Skill requiring one will install BLOCKED against it.
                    """)
            }
        }
    }

    /// A Skill binds to an operation to get a VALUE back. An operation
    /// declaring no output type is one no value-returning Skill can bind to,
    /// which is the whole reason these adapters exist rather than recipes.
    func testEveryDeclaredOperationDeclaresAnOutputType() {
        for adapter in declaredAdapters {
            for operation in adapter.adapterManifest.operations {
                XCTAssertFalse(
                    operation.outputTypes.isEmpty,
                    "\(adapter.name).\(operation.operation) returns no declared Value type.")
            }
        }
    }

    /// Every Value type an operation names must be in the adapter's own
    /// supported list. The two are read by different checks, and a manifest
    /// whose operations reference types it does not claim to support passes
    /// one and fails the other — for reasons that name the type rather than
    /// the inconsistency.
    func testOperationValueTypesAreAllSupportedByTheirAdapter() {
        for adapter in declaredAdapters {
            let manifest = adapter.adapterManifest
            let supported = Set(manifest.supportedValueTypes)
            guard !supported.isEmpty else { continue }
            for operation in manifest.operations {
                for type in operation.inputTypes + operation.outputTypes {
                    XCTAssertTrue(
                        supported.contains(type),
                        """
                        \(adapter.name).\(operation.operation) names \(type), \
                        which the adapter does not list in supportedValueTypes.
                        """)
                }
            }
        }
    }

    /// A perception an operation OBSERVES has to be published by SOMETHING.
    ///
    /// ACROSS BOTH ROSTERS, and the scope is the point rather than a detail.
    /// The typer observes workspace focus and provides none, which is
    /// correct twice over: it CONSUMES a channel, and the channel is
    /// published by an OBSERVER rather than an adapter — `MaryObserver`
    /// turns a workspace sense into exactly this perception. A first version
    /// of this test looked only at adapters, called the typer a bug, and
    /// would have taught the next reader to loosen the rule when the thing
    /// that was wrong was where it looked.
    func testEveryObservedPerceptionIsProvidedBySomething() {
        let provided = Set(adapters.flatMap(\.adapterManifest.providesPerceptions))
            .union(MaryAdapterCatalog.observers().flatMap(\.providedPerceptions))
        for adapter in adapters {
            let observed = Set(
                adapter.adapterManifest.operations.flatMap(\.observesPerceptions))
            for perception in observed {
                XCTAssertTrue(
                    provided.contains(perception),
                    """
                    \(adapter.name) observes \(perception) and nothing in the \
                    catalog provides it, so no Skill requiring it can be eligible.
                    """)
            }
        }
    }

    /// The manifest's own id must be the adapter's. A Skill binds by
    /// `adapterID`, so a mismatch publishes operations nothing can address —
    /// and it is a one-character mistake in a string written four times per
    /// adapter.
    func testEveryManifestCarriesItsOwnAdapterID() {
        for adapter in adapters {
            let manifest = adapter.adapterManifest
            let expected = AdapterID.normalized(adapter.name)
            XCTAssertEqual(
                manifest.adapterID, expected,
                "\(adapter.name)'s manifest is filed under \(manifest.adapterID).")
            for operation in manifest.operations {
                XCTAssertEqual(
                    operation.adapterID, expected,
                    """
                    \(adapter.name).\(operation.operation) is filed under \
                    \(operation.adapterID) rather than \(expected).
                    """)
            }
        }
    }

    /// Every Skill an adapter publishes should have a manifest entry, and
    /// vice versa. A binding with no manifest entry is the default-manifest
    /// bug in miniature; a manifest entry with no binding is a promise
    /// nothing keeps. Checked for ALL adapters — the default manifest is
    /// derived from the bindings, so it satisfies this by construction and a
    /// failure here means a hand-written manifest drifted from its lane.
    func testBindingsAndManifestOperationsAgree() {
        for adapter in adapters {
            let bound = Set(adapter.skillBindings.map(\.name))
            let declared = Set(adapter.adapterManifest.operations.map(\.operation))
            XCTAssertEqual(
                bound, declared,
                """
                \(adapter.name) publishes \(bound.sorted()) as Skills but declares \
                \(declared.sorted()) in its manifest.
                """)
        }
    }
}
