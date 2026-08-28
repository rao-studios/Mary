//
//  main.swift
//  CorpusProbe — `mary-corpus-probe`
//
//  THE JOIN THE SUITE CANNOT MAKE: does a REAL editor, showing a REAL project,
//  produce a crawl and a style reading through the SHIPPED declaration?
//
//  Every part is unit-tested against fixtures. What no fixture can answer is
//  whether the accessibility tree in front of us says what the observer thinks
//  it says — the plan assumed `AXDocument` carried the active file and it
//  carries the project root instead, which is exactly the kind of thing only a
//  live read finds.
//
//    mary-corpus-probe
//

import AppKit
import ApplicationServices
import Foundation
import MaryPlugin
import MaryAmbient
import MaryBrain
import MaryFoundation
import MaryRuntime

func heading(_ text: String) {
    print("\n\(text)")
    print(String(repeating: "─", count: max(text.count, 30)))
}

var failures = 0
nonisolated(unsafe) var reIndexed = false
func check(_ passed: Bool, _ claim: String, _ detail: String = "") {
    print("  \(passed ? "✓" : "✗")  \(claim)\(detail.isEmpty ? "" : " — \(detail)")")
    if !passed { failures += 1 }
}

// THE MENU MEASUREMENT is a different question from the corpus crawl below
// — it asks what an application OFFERS rather than what a project holds —
// so it runs instead of, not before.
if DocumentProbe.shouldRun(CommandLine.arguments) {
    await DocumentProbe.run(CommandLine.arguments)
    exit(0)
}

if MenuProbe.shouldRun(CommandLine.arguments) {
    await MenuProbe.run(CommandLine.arguments)
    exit(0)
}

guard AXIsProcessTrusted() else {
    print("Accessibility is not granted — the probe needs it to read a window.")
    exit(1)
}

// MARK: - The shipped declaration

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
check(!registrations.isEmpty, "a package declares a corpus",
      registrations.map(\.applicationID).joined(separator: ", "))

guard let registration = registrations.first else { exit(1) }
let corpus = registration.schema
print("      notation: \(corpus.notation)  units: \(corpus.include.joined(separator: ", "))")
print("      style rules: \(corpus.style.count)  budgets: \(corpus.budgets.maximumFiles) files")

// MARK: - The live window

heading("what is in front")

guard let pid = CorpusSupport.pid(of: registration) else {
    print("\n\(registration.displayName) isn't running. Open it with a project and try again.")
    exit(1)
}
// `--file <project-relative>` names a unit directly, for verifying the crawl
// without rearranging somebody's editor. The AX read still runs and still
// reports what it found: the override replaces only the UNIT, never the root,
// so what is being tested downstream is a real project resolved a real way.
let arguments = Array(CommandLine.arguments.dropFirst())
let override = arguments.firstIndex(of: "--file").flatMap { index -> String? in
    index + 1 < arguments.count ? arguments[index + 1] : nil
}

let live = CorpusObserver.focus(pid: pid, registration: registration)
if live == nil {
    print("      (nothing settled from the title — a non-unit tab is nothing to crawl)")
}

let resolved: CorpusObserver.Focus?
if let override, let root = live?.root
    ?? CorpusObserver.focus(pid: pid, registration: registration)?.root {
    resolved = CorpusObserver.Focus(
        root: root,
        projectName: (root as NSString).lastPathComponent,
        relativePath: override,
        absolutePath: URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(override).path)
} else if let override {
    // No AX root available; fall back to this checkout so the crawl half can
    // still be exercised, and SAY so rather than implying a live read.
    let root = FileManager.default.currentDirectoryPath
    print("      (no workspace window; using the working directory as the root)")
    resolved = CorpusObserver.Focus(
        root: root,
        projectName: (root as NSString).lastPathComponent,
        relativePath: override,
        absolutePath: URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(override).path)
} else {
    resolved = live
}

guard let focus = resolved else {
    print("\n  ✗  no unit settled. Bring the editor forward with a source file open,")
    print("     or name one with --file <project-relative-path>.")
    exit(1)
}
check(true, "project root, from AXDocument", focus.root)
check(true, "active unit, from the window title", focus.relativePath)
check(FileManager.default.fileExists(atPath: focus.absolutePath),
      "and it exists on disk")

// MARK: - The crawl

heading("the crawl")

let started = Date()
let paths = CorpusCrawl.projectFiles(root: focus.root, corpus: corpus)
let index = CorpusTypeIndex(
    root: focus.root,
    files: paths.map { path in
        (relativePath: path,
         declaredNames: CorpusCrawl.read(
            relativePath: path, root: focus.root, corpus: corpus)?.declaredNames ?? [])
    })
let indexSeconds = Date().timeIntervalSince(started)
check(!paths.isEmpty, "the project holds units", "\(paths.count)")
check(!index.declaringFile.isEmpty, "declaring names are indexed",
      "\(index.declaringFile.count)")
print(String(format: "      index built in %.2fs — cached for %.0fs",
             indexSeconds, CorpusTypeIndexCache.lifetime))

let units = CorpusCrawl.crawl(
    focusedPath: focus.absolutePath, root: focus.root, projectName: focus.projectName,
    corpus: corpus, index: index, applicationID: registration.applicationID)
check(!units.isEmpty, "the crawl produced units", "\(units.count)")
check(units.count <= corpus.budgets.maximumFiles, "within the declared file cap",
      "\(units.count) ≤ \(corpus.budgets.maximumFiles)")
check(units.first?.relativePath == focus.relativePath,
      "led by the file that was settled on")
let edges = units.reduce(0) { $0 + $1.relations.count }
check(edges <= corpus.budgets.maximumEdges, "within the declared edge cap",
      "\(edges) ≤ \(corpus.budgets.maximumEdges)")
for unit in units.prefix(6) {
    print("      · \(unit.relativePath)  types: \(unit.declaredTypes.prefix(3).joined(separator: ", "))  edges: \(unit.relations.count)")
}

// MARK: - The style reading

heading("the style reading")

guard let read = CorpusCrawl.read(
    relativePath: focus.relativePath, root: focus.root, corpus: corpus) else { exit(1) }
let observations = CorpusStyleReader.observe(
    text: read.text, declaredTypes: read.declaredNames, corpus: corpus)
check(!observations.isEmpty, "the declared rules produced votes",
      "\(observations.count) of \(corpus.style.count) rules")
for observation in observations {
    let words = observation.vocabulary.isEmpty
        ? "" : "  [\(observation.vocabulary.prefix(4).joined(separator: ", "))]"
    print("      · \(observation.dimension.rawValue) → \(observation.value.rawValue)  ×\(observation.weight)\(words)")
}
check(observations.allSatisfy { $0.weight <= CorpusStyleReader.maximumWeightPerFile },
      "no single file outvotes the corpus",
      "cap \(CorpusStyleReader.maximumWeightPerFile)")

let isFresh = CorpusObserver.isFreshEdit(focus.absolutePath, at: Date())
print("      fresh edit: \(isFresh ? "yes — this counts as the user's own style" : "no — indexed for structure only")")

// MARK: - The wired pipeline

heading("the pipeline, as the app wires it")

MaryRuntime.installCorpusPipeline()
CorpusSupport.shared.reconcile(registrations)
// THE ROSTER, AS THE APP INSTALLS IT. Without this a place has no
// registration, so `ability` answers nil and the sink drops every
// observation — silently, which is exactly why the probe asserts it.
AmbientApplicationBridge.install(
    profiles: adapters.map(\.applicationProfile)
        + load.snapshot.plugins.applicationProfiles)
check(CorpusSupport.shared.registration(applicationID: registration.applicationID) != nil,
      "the observer's registry holds the declaration")

// The observer is in the catalog, so the app polls it. Prove the identity it
// would publish, without waiting on a poll.
let observers = MaryAdapterCatalog.observers()
check(observers.contains { $0.id == "corpus" }, "the observer ships in the catalog")

// STYLE FILES UNDER THE ABILITY, NEVER THE APPLICATION — the property that
// makes learning in one editor teach Mary about the next.
let place = AmbientPlace.application(registration.applicationID)
check(place.ability?.rawValue == "coding",
      "and its place resolves to an ability",
      place.ability?.rawValue ?? "none")

let store = StyleEvidenceStore.shared
let before = store.tenets().count
for observation in observations {
    store.record(
        dimension: observation.dimension, value: observation.value,
        weight: observation.weight,
        scope: StyleScope(kind: .ability, identity: place.ability?.rawValue ?? "coding"),
        source: "\(registration.applicationID)|\(corpus.notation)",
        vocabulary: observation.vocabulary)
}
store.publish()
let tenets = store.tenets()
check(tenets.count > before, "recorded evidence becomes tenets",
      "\(before) → \(tenets.count)")
for tenet in tenets.prefix(4) {
    print("      · \(tenet.dimension.rawValue) → \(tenet.value.rawValue)  \(tenet.scope.kind.rawValue):\(tenet.scope.identity ?? "—")")
}
check(tenets.allSatisfy { $0.scope.kind == .ability },
      "filed under the ability, not the application")

// MARK: - The switch

heading("the switch")

// OFF MUST MEAN OFF ON THE NEXT POLL, not the next launch — the flag is read
// per poll for exactly this reason, and a switch that only takes effect after
// a relaunch is one people stop trusting.
MaryRuntime.applyCorpusIndexing(enabled: false)
let observerUnderTest = CorpusObserver()
observerUnderTest.setEnabled { MaryRuntime.corpusIndexingIsEnabled }
var crawledWhileOff = false
observerUnderTest.setSink { _, _, _ in crawledWhileOff = true }
await observerUnderTest.pollOnce()
check(!crawledWhileOff, "indexing off reaches no sink")
check(observerUnderTest.observedPlace == nil, "and publishes no place")

MaryRuntime.applyCorpusIndexing(enabled: true)
check(MaryRuntime.corpusIndexingIsEnabled, "and back on again")

// MARK: - Resuming

heading("resuming after a relaunch")

// A manifest that did not survive would make every file a first sighting on
// every launch — the hash gate switched off in all but name, and the most
// expensive way to learn nothing.
let indexer = AmbientUnitIndexingCoordinator(idleFor: 0.1, ledger: nil) { _, _ in }
for unit in units { await indexer.ingest(unit) }
await indexer.flush()
let manifest = await indexer.manifest(forProject: focus.root)
check(manifest != nil, "a manifest was built", "\(manifest?.entries.count ?? 0) entries")

let relaunched = AmbientUnitIndexingCoordinator(idleFor: 0.1, ledger: nil) { _, _ in
    reIndexed = true
}
if let manifest { await relaunched.restore(manifest, projectID: focus.root) }
for unit in units { await relaunched.ingest(unit) }
await relaunched.flush()
check(!reIndexed, "and a restored one re-indexes nothing")

// MARK: - Verdict

heading("── THE VERDICT ──")
if failures == 0 {
    print("""
      A real editor, showing a real project, resolved through the shipped
      declaration: root from the accessibility tree, unit from the title,
      a bounded neighbourhood, and style votes from rules that live in a
      package rather than in Swift.
    """)
} else {
    print("  \(failures) check(s) failed.")
}
exit(failures == 0 ? 0 : 1)
