//
//  AmbientInspectorView.swift
//  Sand
//
//  THE AMBIENT CONTEXT OF THE ACTIVE WINDOW, read as text — the first
//  textual inspector in this app, beside a canvas that has always drawn
//  shapes. What it shows is exactly what `AXEngine.ambientContext` gives
//  Mary's tier-0 ambient store: the active window, the roster of nameable
//  things in reading order, and where focus sits.
//
//  NO LOGIC HERE, deliberately: every string comes from
//  `AXAmbientPresentation` in the engine, where XCTest can reach it (Sand
//  has no test target). This file lays out rows; it never decides one. The
//  one exception is JSON assembly for the selected row — `AXFrameProjection`
//  and `AmbientBridge.record(from:...)` do the actual work, this view only
//  calls them and puts the result on screen.
//
//  SELECTION IS BY ID, RESOLVED EVERY RENDER — the debugger pane's
//  `selectedTile` rule. `model.selectedElement` re-looks-up the id in the
//  CURRENT `model.ambient` on every access, so a stale row can never be
//  shown as if it were still there; `refreshAmbient()` replaces the whole
//  context wholesale on every publish.
//

import AppKit
import MaryComputerUse
import MaryPlugin
import SwiftUI

struct AmbientInspectorView: View {
    @ObservedObject var model: WireframeViewModel
    /// The stage's own height, so the roster's scroll region is budgeted
    /// from what is actually available rather than a constant that can
    /// exceed the window at Sand's minimum size.
    var availableHeight: CGFloat
    @State private var jsonSheetElement: AXNodeID?
    @State private var showsTurnedDown = false

    /// Room left for the roster after the header/focus rows and the
    /// window's own chrome (breadcrumb, toolbar) — a floor keeps a very
    /// short window from collapsing the scroll region to nothing.
    ///
    /// PIN: THE PAGE SECTION IS PAID FOR OUT OF THE SAME BUDGET. On a browser the card
    /// carries a second list, and a roster that kept its whole allowance pushed the
    /// page offers — the half worth reading for a browser — off the bottom of the
    /// window entirely.
    private var rosterBudget: CGFloat {
        max(120, availableHeight - (model.targetIsBrowser ? 560 : 220))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ambient context").font(.headline)
            if let ambient = model.ambient {
                header(ambient)
                focus(ambient)
                roster(ambient)
            } else {
                Text("—").foregroundStyle(.secondary)
            }
            if model.targetIsBrowser {
                pageOffers
                pageRoute
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        // Sizes to its CONTENT, capped — an app offering one control gets a
        // small card, not a box of empty material sitting on top of the
        // wireframe this app exists to show. The roster's own scroll view
        // is what `rosterBudget` bounds (see `roster`).
        .frame(maxWidth: 320, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(item: Binding(
            get: { jsonSheetElement.map(JSONSheetTarget.init) },
            set: { jsonSheetElement = $0?.id }
        )) { target in
            if let element = model.ambient?.elements.first(where: { $0.id == target.id }) {
                ElementJSONSheet(
                    element: element,
                    window: model.ambient?.activeWindow?.frame,
                    capturedAt: model.ambient?.capture.capturedAt ?? Date())
            }
        }
    }

    @ViewBuilder
    private func header(_ ambient: AXAmbientContext) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(AXAmbientPresentation.headerRows(for: ambient)) { entry in
                row(entry.label, entry.value)
            }
        }
    }

    @ViewBuilder
    private func focus(_ ambient: AXAmbientContext) -> some View {
        Divider()
        // "—" rather than a hidden row: nothing claiming focus is a real
        // answer about the screen, not a missing measurement.
        row("Focused", AXAmbientPresentation.focusedLine(for: ambient) ?? "—")
    }

    @ViewBuilder
    private func roster(_ ambient: AXAmbientContext) -> some View {
        Divider()
        let lines = AXAmbientPresentation.elementLines(for: ambient)
        HStack {
            // A BROWSER'S AX TREE IS THE SHELL, AND SAYING SO IS THE WHOLE LESSON.
            // Tabs, the address field and the toolbar are all that is here; nothing
            // inside the page appears in this list, which is exactly why the page lane
            // reads pixels. Calling these rows "on offer" for a browser told the
            // opposite story.
            Text(model.targetIsBrowser ? "Shell (AX)" : "On offer")
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(lines.count) in reading order")
        }
        if lines.isEmpty {
            Text("—").foregroundStyle(.secondary)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    // 120 elements would run off the screen; the roster
                    // scrolls inside `rosterBudget` while the card around it
                    // stays the size of what it actually holds.
                    ForEach(lines) { line in
                        elementRow(line)
                    }
                }
            }
            .frame(maxHeight: rosterBudget)
        }
    }

    /// WHAT THE PAGE ITSELF OFFERS, beneath the shell that cannot see it. Empty until a
    /// read happens, and it says which — "no page read yet" and "read, nothing
    /// reachable" are entirely different findings.
    @ViewBuilder
    private var pageOffers: some View {
        Divider()
        if let roster = model.browserRoster {
            let offers = PageMapProjection.offerLines(for: roster)
            let candidates = PageMapProjection.candidateLines(for: roster)
            HStack {
                Text("Page offers").foregroundStyle(.secondary)
                Spacer()
                // THE GAP IS THE DIAGNOSIS. A results page offering four icons while
                // sixty rows carry real names is the failure this pane exists to show,
                // and the router reaches the second number where nothing else could.
                Text("\(offers.count) of \(roster.elements.count) rows"
                    + (candidates.isEmpty ? "" : " · \(candidates.count) named"))
            }
            Text(PageMapProjection.caption(for: roster))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
            if offers.isEmpty {
                Text("nothing on this page can be named")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(offers) { offer in
                            Text(offer.text)
                                .foregroundStyle(
                                    offer.isEnabled
                                        ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: max(80, availableHeight - 620))
            }
        } else {
            HStack {
                Text("Page offers").foregroundStyle(.secondary)
                Spacer()
                Text("no page read yet").foregroundStyle(.secondary)
            }
        }
    }

    /// WHY THAT ROW AND NOT ANOTHER — the page's answer to the question the ability
    /// roster's pane answers for Skills. Selected first, then anything it could not be
    /// separated from, then every row it turned down with the sentence saying why.
    ///
    /// PIN: THE ROUTE THE LANE ACTUALLY USED, pulled from the engine's own snapshot
    /// beside the roster it was computed against. Nothing here re-runs the router: a
    /// pane that arbitrated for itself would be explaining a decision nobody made.
    @ViewBuilder
    private var pageRoute: some View {
        if let route = model.browserRoute, !route.decisions.isEmpty {
            let lines = PageMapProjection.routeLines(for: route)
            let chosen = lines.filter {
                $0.disposition == .selected || $0.disposition == .clarificationRequired
            }
            Divider()
            HStack {
                Text("Page route").foregroundStyle(.secondary)
                Spacer()
                Text("\(route.selected.count) of \(route.eligibleCount) eligible")
            }
            Text("\"\(route.goal.isEmpty ? "(no words)" : route.goal)\" · \(route.verb)"
                + (route.goalUnmatched ? " · unmatched" : ""))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
            ForEach(chosen) { routeRow($0) }
            if lines.count > chosen.count {
                Button {
                    showsTurnedDown.toggle()
                } label: {
                    Text(showsTurnedDown
                         ? "hide the \(lines.count - chosen.count) not chosen"
                         : "show the \(lines.count - chosen.count) not chosen")
                        .font(.system(size: 9))
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                if showsTurnedDown {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(lines.filter {
                                $0.disposition != .selected
                                    && $0.disposition != .clarificationRequired
                            }) { routeRow($0) }
                        }
                    }
                    .frame(maxHeight: 160)
                }
            }
        }
    }

    private func routeRow(_ line: PageRouteLine) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(line.text)
                .foregroundStyle(
                    line.disposition == .selected ? AnyShapeStyle(.green)
                        : line.disposition == .clarificationRequired
                            ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            Text(line.reason)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// TWO SIBLING BUTTONS, DELIBERATELY NOT ONE NESTED IN THE OTHER. A
    /// `Button` inside another `Button`'s label collapses to one
    /// accessibility element — measured live: the JSON control rendered
    /// and was clickable by mouse, but neither VoiceOver nor Sand's own
    /// AX-driven verification could reach it, because the outer button
    /// swallowed it. The row (selection) and the JSON control (detail) are
    /// independently pressable instead.
    @ViewBuilder
    private func elementRow(_ line: AXAmbientPresentation.ElementLine) -> some View {
        let isSelected = model.selectedElementID?.raw == line.id
        HStack(alignment: .top, spacing: 6) {
            Button {
                model.selectElement(AXNodeID(raw: line.id))
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    Text(line.text)
                        // Focus is the yellow the canvas already strokes a
                        // focused node with; a disabled control is
                        // perceived but not offered, and reads that way.
                        .foregroundStyle(
                            line.isFocused ? AnyShapeStyle(.yellow)
                                : line.isEnabled ? AnyShapeStyle(.primary)
                                : AnyShapeStyle(.tertiary))
                    if let trail = line.trail {
                        Text(trail)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isSelected {
                Button("JSON") { jsonSheetElement = AXNodeID(raw: line.id) }
                    .buttonStyle(.plain)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.blue)
            }
        }
        .padding(.vertical, 1)
        .background(
            isSelected
                ? RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.18))
                : nil)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).multilineTextAlignment(.trailing)
        }
    }
}

/// `.sheet(item:)` needs `Identifiable`; `AXNodeID` alone is not (it is a
/// diffing hint over CFHash, deliberately minimal). This wraps just enough.
private struct JSONSheetTarget: Identifiable {
    let id: AXNodeID
}

/// The button's answer to "what and where" — the selected element's full
/// addressing record (`AXElementRecord`), as JSON. `AXFrame` stays pure
/// geometry inside it; this is what shows how the frame attaches to the
/// thing it locates.
private struct ElementJSONSheet: View {
    let element: AXScreenElement
    let window: CGRect?
    let capturedAt: Date
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    private var json: String {
        let record = AmbientBridge.record(from: element, window: window, capturedAt: capturedAt)
        return AXFrameProjection.json(record) ?? "(encoding failed)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("AXElementRecord").font(.headline)
                Spacer()
                Button(copied ? "Copied" : "Copy") { copy() }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            ScrollView {
                Text(json)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(minWidth: 440, minHeight: 280, maxHeight: 480)
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(json, forType: .string)
        copied = true
    }
}
