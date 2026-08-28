//
//  main.swift
//  BehaviorProbe — `mary-behavior-probe`
//
//  THE ONE THING THE SUITE CANNOT ANSWER about the behavioral codec: does a
//  REAL turn, against a REAL application, produce an episode whose fields are
//  actually filled?
//
//  Every part of the codec is unit-tested — the assembler's lifecycle, the
//  chokepoint's completeness, the store's durability, the resolver's ladder.
//  What no test can check is whether the pieces meet: whether the element a
//  skill touched has a real frame in it, whether the capture holds the
//  surfaces the prompt was actually given, whether the realm names the place
//  the turn went to. Each of those is a JOIN between a live accessibility
//  read and a value composed three layers away, and a join is exactly what a
//  test with fixtures on both ends cannot exercise.
//
//    mary-behavior-probe                 # read: the last sealed episode
//    mary-behavior-probe --live          # drive a real turn, then read it back
//
//  IT WRITES TO A REAL DOCUMENT under `--live`, so it makes its own scratch
//  note and refuses to touch anything else — the same trade `--prose --write`
//  makes, for the same reason.
//

import AppKit
import Foundation
import MaryPlugin
import MaryAmbient
import MaryBrain
import MaryFoundation
import MaryRuntime

// MARK: - Reporting

func heading(_ text: String) {
    print("\n\(text)")
    print(String(repeating: "─", count: max(text.count, 30)))
}

func check(_ passed: Bool, _ claim: String, _ detail: String = "") {
    print("  \(passed ? "✓" : "✗")  \(claim)\(detail.isEmpty ? "" : " — \(detail)")")
    if !passed { failures += 1 }
}

var failures = 0

/// A store in a temporary directory: the probe must never write into the
/// user's own record, and must never purge it either.
let directory = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("mary-behavior-probe", isDirectory: true)
try? FileManager.default.removeItem(at: directory)
let store = BehavioralStore(directory: directory)
let assembler = BehavioralAssembler(recorder: store)

let arguments = Array(CommandLine.arguments.dropFirst())
let isLive = arguments.contains("--live")

guard AXIsProcessTrusted() else {
    print("Accessibility is not granted — the probe needs it to read a surface.")
    exit(1)
}

// MARK: - The world

heading("the roster")

// THE SHIPPED CONFIGURATION, NOT A FIXTURE. This section used to hand-build
// the registration and the profile it wanted to see, which proved the prose
// lane works and said nothing at all about whether `Abilities/textedit.mary`
// declares it correctly — the only question a live parity pass is for. What
// runs here is `installBrainConfiguration`'s steps 1-3, verbatim, minus the
// brain: the same seams, the same load, the same reconcile.
ProseSurfaceSupport.shared.installBackingResolver()
AmbientCapabilityBridge.install()

let adapters = MaryAdapterCatalog.adapters()
let observers = MaryAdapterCatalog.observers()
let load = AbilityLibrary.shared.configureAndLoad(
    adapterManifests: MaryAdapterCatalog.adapterManifests(
        adapters: adapters, observers: observers),
    nativeApplicationProfiles: adapters.map(\.applicationProfile),
    primitiveBindings: [])
check(load.activated, "the packages loaded",
      "\(load.snapshot.records.count): "
        + load.snapshot.records.map(\.package.ability.id.rawValue).sorted()
            .joined(separator: ", "))
for issue in load.issues where issue.severity == .error {
    print("      ! \(issue.code): \(issue.message)")
}

let registrations = MaryRuntime.proseSurfaceRegistrations(from: load.snapshot)
ProseSurfaceSupport.shared.reconcile(registrations)
AmbientApplicationBridge.install(
    profiles: adapters.map(\.applicationProfile)
        + load.snapshot.plugins.applicationProfiles)

guard let registration = registrations.first(
    where: { $0.bundleIdentifiers.contains("com.apple.TextEdit") })
else {
    print("\n  ✗  no package declares a prose surface for TextEdit.")
    exit(1)
}
check(true, "the editor's prose surface is declared", registration.applicationID)

let place = AmbientPlace.application(registration.applicationID)
check(place.hasEyes, "the declared place has eyes")
// A DISCIPLINE IS EARNED BY REALIZING A SKILL, never declared — so this line
// is really asking whether `textedit.mary`'s realization of a `writing` skill
// reached the compiled profile.
check(place.focus == .writing, "and a discipline",
      "\(place.focus.map(String.init(describing:)) ?? "none") from ["
        + (place.registration?.profile.abilities.map(\.rawValue).sorted()
            .joined(separator: ", ") ?? "no registration") + "]")

guard let pid = ProseSurfaceSupport.pid(of: registration) else {
    print("\n\(registration.displayName) isn't running. Open it and try again.")
    exit(1)
}

// MARK: - Tier 0

heading("the surface")

// THE OBSERVER READS WHAT IS IN FRONT, which is the whole point of a tier-0
// surface: it is the screen the user is looking at, not a screen we went
// looking for. Launched from a terminal, the thing in front is the terminal —
// so the probe must actually put the editor there, the same way a real turn
// only ever happens while the user is already looking at it. (This is how the
// first run of this probe failed: one surface in the store, keyed to the
// terminal, and a lead that named the editor.)
let activation = await VerifiedActivation.bringForward(pid: pid, requireVisibleWindow: true)
check(activation.succeeded, "the editor came forward",
      activation.road.map(String.init(describing:))
          ?? activation.reason(app: registration.displayName) ?? "refused")

let observer = AmbientSurfaceObserver.shared
observer.pollOnce(at: Date())
let surface = AmbientContextStore.shared.surface(place: place, at: Date())
check(surface != nil, "the observer published a surface for the place",
      AmbientContextStore.shared.surfaces()
          .map(\.place.token).joined(separator: ", "))
if let surface {
    print("      \(surface.surfaceLine(at: Date()))")
    check(!surface.elements.isEmpty, "with elements", "\(surface.elements.count)")
    // The surface tier's frame IS optional — an element whose geometry could
    // not be read still rides, counted. So "carrying frames" means some
    // element has one with size, not merely that the field is populated.
    check(surface.elements.contains { ($0.frame?.rect.width ?? 0) > 0 },
          "carrying frames",
          "\(surface.elements.filter { $0.frame != nil }.count) of \(surface.elements.count)")
}

// MARK: - The realm

heading("the realm")

let realm = AmbientRealmResolver.resolve(.init(
    utterance: "tidy up this note",
    discipline: .writing,
    decidedBy: .writingRegister,
    focus: FocusSignal(lead: place),
    evidence: [place: FocusEvidence(place: place, kind: .activation, at: Date())]))

check(!realm.need.isEmpty || realm.need.discipline != nil, "the need is stated")
check(!realm.candidates.isEmpty, "candidates were found", "\(realm.candidates.count)")
check(realm.place == place, "and the place is the lead", realm.place?.token ?? "none")
if let candidate = realm.candidates.first {
    check(candidate.conformsByDiscipline, "the candidate conforms by discipline")
    check(!candidate.targetClasses.isEmpty,
          "carrying its declared target classes",
          candidate.targetClasses.sorted().joined(separator: ", "))
    check(candidate.evidence != nil, "and its standing", "\(candidate.evidence.map(String.init(describing:)) ?? "cold")")
}

// MARK: - The capture

heading("the capture")

let facts = AmbientContextStore.shared.facts()
let rendering = AmbientRanker.render(
    facts: facts,
    utterance: "tidy up this note",
    focusedPlace: place,
    surfaces: AmbientContextStore.shared.surfaces(),
    budget: AmbientRanker.abilityBudget)

let captureStart = Date()
let capture = AmbientCaptureBuilder.capture(
    facts: facts,
    surfaces: AmbientContextStore.shared.surfaces(),
    rendering: rendering,
    lead: place,
    realm: realm)
let captureMicroseconds = Date().timeIntervalSince(captureStart) * 1_000_000

check(capture.lead == place.token, "the capture names the lead", capture.lead ?? "none")
check(!capture.surfaces.isEmpty, "and holds the surfaces", "\(capture.surfaces.count)")
// A COUNT IS NOT A JOIN. "One surface" was true on the run that captured the
// terminal's screen under a lead that named the editor; what has to be true is
// that the screen in the capture is the screen the turn is about.
check(capture.surfaces.contains { $0.place == place.token },
      "one of which is the lead's own screen",
      capture.surfaces.map(\.place).joined(separator: ", "))
check(capture.realm != nil, "and the realm")
check(capture.realm?.place == capture.lead,
      "realm.place == lead",
      "\(capture.realm?.place ?? "nil") vs \(capture.lead ?? "nil")")
print(String(format: "      built in %.0f µs", captureMicroseconds))

// MARK: - The turn

heading(isLive ? "a real turn" : "a dispatched turn (no writes)")

let turn = UUID()
assembler.openEpisode(
    id: turn,
    query: "tidy up this note",
    provenance: EpisodeProvenance(engine: "probe", lane: "dual", appVersion: "probe"))
assembler.stageCapture(capture)
assembler.claimStagedCapture(forEpisode: turn)

let log = AbilityExecutionLog()
let runtime = AbilityRuntime(
    plugins: MaryAdapterCatalog.adapters(),
    executionLog: log,
    behavior: assembler,
    contextProvider: { AbilityExecutionContext(projects: [:]) })

// THE READ PATH ALWAYS RUNS: it touches nothing, and it is the one that
// proves an acted element reaches the record with a frame on it.
_ = await runtime.dispatch(name: "list_documents", argumentsJSON: #"{"app":"textedit"}"#)
_ = await runtime.dispatch(name: "read_document", argumentsJSON: #"{"app":"textedit"}"#)

if isLive {
    // A NOTE THE PROBE MAKES, and the only one it will touch.
    let outcome = await runtime.dispatch(
        name: "create_document", argumentsJSON: #"{"app":"textedit"}"#)
    print("      create: \(outcome.summary)")
    if outcome.ok {
        _ = await runtime.dispatch(
            name: "type_at_cursor",
            argumentsJSON: #"{"app":"textedit","text":"Mary wrote this."}"#)
    }
}

assembler.seal(turn, reason: .completed)

// The hand-off is detached; give it a moment to land.
for _ in 0..<200 where await store.allEpisodes().episodes.isEmpty {
    try? await Task.sleep(nanoseconds: 2_000_000)
}

// MARK: - Reading it back

heading("the episode, off disk")

let read = await store.allEpisodes()
check(read.skipped == 0, "no lines were skipped")
guard let episode = read.episodes.first else {
    print("  ✗  nothing was written")
    exit(1)
}

check(episode.id == turn, "one episode, with the turn's own id")
check(episode.sealedReason == .completed, "sealed completed")
check(episode.input.query == "tidy up this note", "carrying the query")
check(episode.input.ambient != nil, "and the injected context")
check(episode.input.ambient?.realm?.place == place.token,
      "whose realm names the place",
      episode.input.ambient?.realm?.place ?? "none")
check(!(episode.input.ambient?.surfaces.isEmpty ?? true),
      "and the surfaces the prompt was given",
      "\(episode.input.ambient?.surfaces.count ?? 0)")
check(!episode.output.actions.isEmpty,
      "with actions", "\(episode.output.actions.count)")

for action in episode.output.actions {
    let target = action.action.target
    let frame = target.map {
        String(format: "%.0f×%.0f", $0.frame.rect.width, $0.frame.rect.height)
    } ?? "—"
    print("""
          · \(action.action.intention)  \(action.disposition.rawValue)
            target: \(target?.role ?? "none")  frame: \(frame)  \
    window: \(target?.windowTitle ?? "—")
            adapters: \(action.action.adapters.map(\.rawValue).joined(separator: " → "))
    """)
}

// THE JOIN THAT NOTHING ELSE CAN CHECK: a real accessibility read reaching a
// value composed three layers away, with its geometry intact.
let acted = episode.output.actions.compactMap(\.action.target)
check(!acted.isEmpty, "at least one action named the element it touched")
// A ZERO-SIZED FRAME IS NOT A FRAME. `AXFrame` is not optional, so the only
// way to tell "we read the geometry" from "we defaulted it" is the geometry
// itself — and a text area with no width is a read that did not happen.
check(acted.contains { $0.frame.rect.width > 0 && $0.frame.rect.height > 0 },
      "with a real frame on it",
      acted.first.map {
          String(format: "%.0f×%.0f", $0.frame.rect.width, $0.frame.rect.height)
      } ?? "—")
check(episode.output.actions.allSatisfy { !$0.action.adapters.isEmpty },
      "and every action names its adapter trail")

// THE WRITE, SPECIFICALLY. "Some action carried a target" was true while the
// typer carried none — the prose reader's record satisfied it on its own. The
// gate is about the act that CHANGED something: a typing turn has to name the
// text area the keystrokes went into, or the record of the one thing Mary did
// to the user's document says only that it happened somewhere.
if isLive {
    let typed = episode.output.actions.first { $0.action.intention == "type_at_cursor" }
    check(typed != nil, "the write is in the episode")
    if let target = typed?.action.target {
        check(target.role == "AXTextArea", "and names a text area", target.role)
        check(target.frame.rect.width > 0 && target.frame.rect.height > 0,
              "with a real frame",
              String(format: "%.0f×%.0f at %.0f,%.0f",
                     target.frame.rect.width, target.frame.rect.height,
                     target.frame.rect.x, target.frame.rect.y))
        check(!target.windowTitle.isEmpty, "in a named window", target.windowTitle)
    } else {
        check(false, "and names the element it typed into", "no target")
    }

    // THE TWO ACTS AGREE ABOUT WHICH DOCUMENT. The create hands the typer its
    // surface, so the note that was made and the note that was written into
    // are one note — and if the two records disagree, one of them is naming a
    // document nobody touched. This is the check that caught the create
    // reporting the backmost window.
    let created = episode.output.actions
        .first { $0.action.intention == "create_document" }?.action.target
    check(created?.windowTitle == typed?.action.target?.windowTitle,
          "and the create named the same note the write went into",
          "\(created?.windowTitle ?? "—") vs \(typed?.action.target?.windowTitle ?? "—")")
}

// MARK: - The switch

heading("the switch")

let offDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("mary-behavior-probe-off", isDirectory: true)
try? FileManager.default.removeItem(at: offDirectory)
let silent = BehavioralStore(directory: offDirectory, isEnabled: { false })
await silent.append(episode)
check(await silent.files().isEmpty, "recording off writes no file")
check(!FileManager.default.fileExists(atPath: offDirectory.path),
      "and does not even create the directory")

// MARK: - Verdict

heading("── THE VERDICT ──")
if failures == 0 {
    print("""
      A real turn produced ONE episode carrying the query, the ambient
      context that was actually injected for it, the realm that chose the
      place, and every action with the element it touched — frame and all.
      The codec's halves meet.
    """)
} else {
    print("  \(failures) check(s) failed. The episode above is what was written.")
}
try? FileManager.default.removeItem(at: directory)
try? FileManager.default.removeItem(at: offDirectory)
exit(failures == 0 ? 0 : 1)
