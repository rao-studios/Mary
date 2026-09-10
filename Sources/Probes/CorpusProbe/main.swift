//
//  main.swift
//  CorpusProbe — `mary-corpus-probe`
//
//  WHAT: Live editor + real project through the shipped declaration (join the suite cannot make).
//  OUT:  CLI: mary-corpus-probe
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

// Live buffer/selection lane. Own flag so ProjectProbe's "project" token cannot shadow it.
if CodeSurfaceProbe.shouldRun(CommandLine.arguments) {
    await CodeSurfaceProbe.run(CommandLine.arguments)
    exit(failures == 0 ? 0 : 1)
}

// The awareness faculty: the unit at the cursor and what reaches it. Own
// flag, beside the code-surface lanes it reads through.
if AwarenessProbe.shouldRun(CommandLine.arguments) {
    await AwarenessProbe.run(CommandLine.arguments)
    exit(failures == 0 ? 0 : 1)
}

// Write-side sibling. Own flag, checked immediately after CodeSurfaceProbe.
if CodeSurfaceWriteProbe.shouldRun(CommandLine.arguments) {
    await CodeSurfaceWriteProbe.run(CommandLine.arguments)
    exit(failures == 0 ? 0 : 1)
}

// Fourth-channel perception. Own flag — must not be shadowed by ProjectProbe.
if ScrivenerPerceptionProbe.shouldRun(CommandLine.arguments) {
    await ScrivenerPerceptionProbe.run(CommandLine.arguments)
    exit(failures == 0 ? 0 : 1)
}

// Explicit-app rung. Own flag, beside the perception lane above.
if ScrivenerPerceptionProbe.shouldRunExplicitApp(CommandLine.arguments) {
    await ScrivenerPerceptionProbe.runExplicitApp(CommandLine.arguments)
    exit(failures == 0 ? 0 : 1)
}

// THE FRONTMOST RUNG, on its own, with no corpus precondition — see
// `ScrivenerPerceptionProbe.runFrontmostOnly`'s header.
if ScrivenerPerceptionProbe.shouldRunFrontmostOnly(CommandLine.arguments) {
    await ScrivenerPerceptionProbe.runFrontmostOnly(CommandLine.arguments)
    exit(failures == 0 ? 0 : 1)
}

// THE ANNOTATION ROUND — the one step that costs a model round, and the only
// one that can fail against a live server. Its own flag, checked before
// `ProjectProbe.shouldRun`'s broader match, same reasoning as the lanes above.
if AnnotationProbe.shouldRun(CommandLine.arguments) {
    exit(Int32(await AnnotationProbe.run(CommandLine.arguments)))
}

// READING A PROJECT off disk is its own question — the shape of one
// manuscript, not the style of a body of files — and needs no AX at all,
// so it runs before the grant check below.
if ProjectProbe.shouldRun(CommandLine.arguments) {
    await ProjectProbe.run(CommandLine.arguments)
    // `--dispatch` accumulates into the same `check`/`failures` this file
    // declares; every other mode leaves `failures` at 0, so this stays
    // byte-identical for them.
    exit(failures == 0 ? 0 : 1)
}

// THE MENU MEASUREMENT is a different question from the corpus crawl below
// — it asks what an application OFFERS rather than what a project holds —
// so it runs instead of, not before.
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

// Crawl registrations that declare include extensions, not project-only corpora.
let crawlable = registrations.filter { !$0.schema.include.isEmpty }
let wantedApp = CommandLine.arguments.firstIndex(of: "--app").flatMap { index -> String? in
    index + 1 < CommandLine.arguments.count ? CommandLine.arguments[index + 1] : nil
}
guard let registration = wantedApp.flatMap({ named in
    crawlable.first { $0.applicationID.caseInsensitiveCompare(named) == .orderedSame }
}) ?? crawlable.first(where: { CorpusSupport.pid(of: $0) != nil }) ?? crawlable.first else {
    print("  ✗ no declared corpus names any file extension to crawl.")
    exit(1)
}
check(true, "the corpus under test", registration.applicationID
    + (crawlable.count > 1 ? "  (of \(crawlable.count) crawlable)" : ""))
let corpus = registration.schema
print("      notation: \(corpus.notation)  units: \(corpus.include.joined(separator: ", "))")
print("      style rules: \(corpus.style.count)  budgets: \(corpus.budgets.maximumFiles) files")

// MARK: - The live window

heading("what is in front")

guard let pid = CorpusSupport.pid(of: registration) else {
    print("\n\(registration.displayName) isn't running. Open it with a project and try again.")
    exit(1)
}
// `--file` overrides the unit only; AX still reads a real project root.
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
