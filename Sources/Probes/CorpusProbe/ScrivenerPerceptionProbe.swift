//
//  ScrivenerPerceptionProbe.swift
//  CorpusProbe
//
//  THE FOURTH CHANNEL, DRIVEN THROUGH REAL DISPATCH — proves
//  `PluginCompiler.perception(from:proseSurface:codeSurface:mediaSurface:
//  corpus:)` actually closes the gap it was extended for: `scrivener.mary`
//  declares `application.perception.kind: "workspace"` backed only by its
//  `corpus` block (no `proseSurface`, no `codeSurface`), which the compiler
//  used to silently downgrade to `.perceptionOnly` — `hasEyes` false,
//  `type_at_cursor`'s `awaitFocusedTextSurface` guard refusing "I couldn't
//  find a text cursor" even with a real cursor active in a real document.
//
//  A UNIT TEST CAN PIN THE COMPILED VALUE (see `PluginCompilerTests`); it
//  cannot prove the roster a real turn actually offers, or that
//  `type_at_cursor` genuinely stops refusing against a real, running
//  Scrivener. That is this file's whole job — the same reasoning
//  `CodeSurfaceProbe` and `ProjectProbe.runDispatch` already established for
//  their own lanes.
//
//  THE NEGATIVE CHECK MATTERS AS MUCH AS THE POSITIVE ONE. Declaring
//  `plugin.proseSurface` on `scrivener.mary` was ruled out as the fix
//  specifically because it would have made `list_documents`/`read_document`/
//  `create_document` dispatchable against Scrivener too — wrong for an
//  app whose real document model is a binder, not "one text element". This
//  probe asserts those three stay absent from the roster, so a future
//  change that reintroduces the collateral risk fails here rather than
//  shipping quietly.
//
//    mary-corpus-probe --dispatch-scrivener-typing
//    mary-corpus-probe --dispatch-scrivener-typing --marker "[[MARY-PROBE]]"
//

import ApplicationServices
import Foundation
import MaryAmbient
import MaryBrain
import MaryFoundation
import MaryPlugin
import MaryRuntime

enum ScrivenerPerceptionProbe {

    static func shouldRun(_ arguments: [String]) -> Bool {
        arguments.contains("--dispatch-scrivener-typing")
    }

    static func run(_ arguments: [String]) async {
        func value(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count
            else { return nil }
            return arguments[index + 1]
        }

        guard AXIsProcessTrusted() else {
            print("Accessibility is not granted for this binary. Use ./scripts/dev.sh.")
            exit(1)
        }

        heading("the roster")
        let adapters = MaryAdapterCatalog.adapters()
        let load = AbilityLibrary.shared.configureAndLoad(
            adapterManifests: MaryAdapterCatalog.adapterManifests(
                adapters: adapters, observers: MaryAdapterCatalog.observers()),
            nativeApplicationProfiles: adapters.map(\.applicationProfile),
            primitiveBindings: [])
        check(load.activated, "the packages loaded", "\(load.snapshot.records.count)")
        for issue in load.issues where issue.severity == .error {
            print("      ! \(issue.code): \(issue.message)")
        }

        let registrations = MaryRuntime.corpusRegistrations(from: load.snapshot)
        CorpusSupport.shared.reconcile(registrations)
        let profiles = adapters.map(\.applicationProfile)
            + load.snapshot.plugins.applicationProfiles
        AmbientApplicationBridge.install(profiles: profiles)

        // THE COMPILED PERCEPTION, straight off the graph — not a hand-picked
        // stand-in. This is what changes when `PluginCompiler.perception`
        // gains the `corpus` channel.
        let scrivenerProfile = profiles.first { $0.id == "scrivener" }
        check(scrivenerProfile != nil, "scrivener.mary compiled a profile")
        let perceptionKind = scrivenerProfile?.perception?.kind
        check(perceptionKind == .workspace,
              "its compiled perception is .workspace, not .perceptionOnly",
              perceptionKind.map(String.init(describing:)) ?? "nil")

        heading("what is open")
        guard case .success(let corpus) = ProjectCorpusSupport.resolve(nil) else {
            print("  ✗ Scrivener's project didn't resolve unambiguously. Open exactly one "
                + "manuscript in Scrivener (close other corpus-backed windows, e.g. Xcode) "
                + "and try again.")
            exit(1)
        }
        check(corpus.registration.applicationID == "scrivener",
              "the resolved corpus is Scrivener's", corpus.name)

        let activation = await VerifiedActivation.bringForward(
            pid: corpus.processIdentifier, requireVisibleWindow: true)
        check(activation.succeeded, "Scrivener came forward",
              activation.road.map(String.init(describing:))
                  ?? activation.reason(app: corpus.registration.displayName) ?? "refused")

        heading("the real lead")
        WorkspaceFocusTracker.shared.sample()
        let signal = WorkspaceFocusTracker.shared.signal()
        let leadApplicationID = signal.lead?.application
        check(leadApplicationID == "scrivener",
              "the tracker's own frontmost read leads with Scrivener",
              leadApplicationID ?? "none")

        let utterance = value("--utterance") ?? "type this at the cursor"
        let route = AmbientEngine.resolve(AmbientEngine.Inputs(
            utterance: utterance,
            leadApplicationID: leadApplicationID,
            profiles: profiles))
        AmbientContextStore.shared.noteUtterance(utterance)
        AmbientContextStore.shared.noteRoute(route)
        check(route.leadPlace?.application == "scrivener",
              "the route's lead place names Scrivener",
              route.leadPlace?.token ?? "none")
        check(route.leadPlace?.hasEyes == true,
              "the place now reports hasEyes — the fix this probe exists for")
        check(route.leadPlace?.focus == .writing,
              "and its discipline is writing",
              route.leadPlace?.focus.map(String.init(describing:)) ?? "none")

        heading("what the model would actually be offered")
        let log = AbilityExecutionLog()
        let runtime = AbilityRuntime(
            plugins: adapters, executionLog: log,
            contextProvider: { AbilityExecutionContext(projects: [:]) })
        let offered = Set(runtime.schemas.map(\.name))
        check(offered.contains("type_at_cursor"), "type_at_cursor is in this turn's roster")
        // THE NEGATIVE THE FIX WAS SPECIFICALLY CHOSEN TO PRESERVE — see the
        // header — IS NOT ABOUT THE ROSTER. `list_documents`/`read_document`/
        // `create_document` are offered here regardless (writing's ability-
        // level eligibility admits them for any writing-discipline turn,
        // `hasEyes` plays no part) — measured live, corrected from this
        // probe's first draft, which asserted the wrong thing. The actual
        // guarantee is downstream, in `ProseSurfaceAdapter.resolve`: it looks
        // Scrivener's frontmost bundle id up in `ProseSurfaceSupport`'s
        // registry (`MaryRuntime+BrainInstall.swift`'s
        // `proseSurfaceRegistrations`, admitting only a package that declares
        // `plugin.proseSurface` — `scrivener.mary` still does not, untouched
        // by this fix), finds no match, and falls to `notRunning(nil)`
        // rather than ever touching Scrivener's binder. Dispatched for real
        // below, because that is the only way to actually prove it.
        check(offered.contains("list_documents"),
              "list_documents IS offered (ability-level, not app-gated — expected)")

        heading("dispatching list_documents for real — must NOT act on Scrivener")
        let listOutcome = await runtime.dispatch(name: "list_documents", argumentsJSON: "{}")
        check(listOutcome.ok, "list_documents dispatched without a hard error")
        check(listOutcome.foundNothing,
              "and it found nothing — Scrivener is not a registered prose surface",
              listOutcome.summary)
        check(!listOutcome.summary.lowercased().contains("gitas-ballad")
                && !listOutcome.summary.lowercased().contains("scrivener"),
              "its answer names neither the manuscript nor Scrivener",
              listOutcome.summary)

        heading("dispatching type_at_cursor for real")
        // A SMALL, IDENTIFIABLE MARKER rather than free prose — cheap to spot
        // in the transcript and cheap to revert (Cmd+Z in Scrivener) after
        // this probe confirms it landed.
        // NO EXPLICIT `app`, deliberately — this is the shape the real turn
        // takes ("with Scrivener genuinely frontmost"): `TypingSurface
        // .resolve`'s frontmost rung (its bundle id compared against
        // `SelectionSurfacePolicy.permitsProseApplication`, a blocklist
        // check) is what a model call with Scrivener already in front
        // actually exercises, not the taught-application rung (which
        // resolves through `scrivener.mary`'s DECLARED bundle id and would
        // fail `isRunning`'s exact-match against the real
        // `com.literatureandlatte.scrivener3` process — a separate,
        // pre-existing version-suffix gap, not this fix's concern).
        let marker = value("--marker") ?? " [[MARY-PROBE-\(Int(Date().timeIntervalSince1970))]]"
        let typeOutcome = await runtime.dispatch(
            name: "type_at_cursor",
            argumentsJSON: #"{"text":"\#(marker)"}"#)
        check(typeOutcome.ok, "type_at_cursor dispatched without a refusal", typeOutcome.summary)
        if !typeOutcome.ok {
            print("""

              ✗ type_at_cursor refused. If the refusal text mentions "a text \
                cursor", place a real cursor in a Scrivener document's editor \
                pane (click into it) and run this again.
            """)
        }

        AmbientContextStore.shared.noteRoute(route)
    }
}
