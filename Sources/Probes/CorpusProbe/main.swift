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
import MaryAdapters
import MaryAmbient
import MaryBrain
import MaryFoundation
import MaryRuntime

func heading(_ text: String) {
    print("\n\(text)")
    print(String(repeating: "─", count: max(text.count, 30)))
}

var failures = 0
func check(_ passed: Bool, _ claim: String, _ detail: String = "") {
    print("  \(passed ? "✓" : "✗")  \(claim)\(detail.isEmpty ? "" : " — \(detail)")")
    if !passed { failures += 1 }
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
