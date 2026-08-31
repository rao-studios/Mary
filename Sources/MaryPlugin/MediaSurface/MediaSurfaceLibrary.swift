//
//  MediaSurfaceLibrary.swift
//  MaryPlugin
//
//  WHAT: Playlists from AXOutline; play is page Play, not transport Play.
//  PIN:  Distinguish by scope+size (outside transport, largest wins).

import ApplicationServices
import Foundation
import MaryAmbient
import MaryFoundation

public enum MediaSurfaceLibrary {

    // MARK: - Reading the playlists

    /// The user's playlists, in sidebar order. Empty when the package declared no library,
    /// when the outline is not on screen, or when the section header is missing.
    public static func playlists(
        pid: pid_t, registration: MediaSurfaceRegistration
    ) async -> [String] {
        guard let rows = await revealedRows(pid: pid, registration: registration) else {
            return []
        }
        return playlistNames(from: rows.map(\.name), registration: registration)
    }

    /// The library's rows, revealing the library first if it is not on screen.
    private static func revealedRows(
        pid: pid_t, registration: MediaSurfaceRegistration
    ) async -> [Row]? {
        if let rows = await sidebarRows(pid: pid, registration: registration), !rows.isEmpty {
            return rows
        }
        guard let reveal = registration.schema.libraryRevealLabel,
              await pressButton(labelled: reveal, pid: pid, registration: registration)
        else { return await sidebarRows(pid: pid, registration: registration) }
        try? await Task.sleep(nanoseconds: 700_000_000)
        return await sidebarRows(pid: pid, registration: registration)
    }

    /// Press the first button anywhere in the player wearing this label.
    private static func pressButton(
        labelled label: String, pid: pid_t, registration: MediaSurfaceRegistration
    ) async -> Bool {
        guard let built = AXSnapshotBuilder.build(pid: pid, options: .exhaustive)
        else { return false }
        let folded = MediaSurfaceRegistration.folded(label)
        var hit: AXNodeID?
        func walk(_ node: AXNodeSnapshot) {
            guard hit == nil else { return }
            if node.role.contains("Button"),
               MediaSurfaceRegistration.folded(node.label ?? "") == folded {
                hit = node.id
                return
            }
            for child in node.children { walk(child) }
        }
        for window in built.snapshot.windows where hit == nil {
            if let root = window.root { walk(root) }
        }
        guard let hit, let element = built.elements[hit] else { return false }
        return await press(element, pid: pid)
    }

    /// The section rule, pulled out so it can be tested without a live player.
    static func playlistNames(
        from rows: [String], registration: MediaSurfaceRegistration
    ) -> [String] {
        guard let section = registration.schema.playlistSectionLabel else { return [] }
        let folded = MediaSurfaceRegistration.folded(section)
        guard let start = rows.firstIndex(where: {
            MediaSurfaceRegistration.folded($0) == folded
        }) else { return [] }
        let skips = Set(registration.schema.playlistSectionSkips
            .map(MediaSurfaceRegistration.folded))
        return rows[rows.index(after: start)...].filter { name in
            !name.isEmpty && !skips.contains(MediaSurfaceRegistration.folded(name))
        }
    }

    // MARK: - Playing

    public enum Outcome: Sendable, Equatable {
        case played(String)
        /// Played under `SpokenTitleCommitContext` — the best guess, not an
        /// exact spoken match. The caller must say so, not just "Playing X".
        case playedAsGuess(String)
        case noSuchPlaylist([String])
        /// Two playlists answered to the same spoken name. NAMED, NEVER
        /// GUESSED: starting one of two is a coin flip the user did not ask
        /// for, and the wrong one is audible immediately.
        case ambiguous([String])
        case noLibrary
        case couldNotPress
    }

    /// Select a playlist by name, then start it. MATCHED THE WAY IT WAS SPOKEN.
    public static func play(
        playlistNamed name: String, pid: pid_t, registration: MediaSurfaceRegistration
    ) async -> Outcome {
        guard let rows = await revealedRows(pid: pid, registration: registration) else {
            return .noLibrary
        }
        let offered = playlistNames(from: rows.map(\.name), registration: registration)
        guard !offered.isEmpty else { return .noLibrary }

        let resolved: String
        var wasGuess = false
        switch SpokenTitleMatcher.resolve(name, in: offered) {
        case .match(let title): resolved = title
        case .guessed(let title): resolved = title; wasGuess = true
        case .ambiguous(let titles): return .ambiguous(titles)
        case .none(let closest): return .noSuchPlaylist(closest)
        }
        guard let row = rows.first(where: { $0.name == resolved }) else {
            return .noSuchPlaylist(offered)
        }

        var selected = await selectRow(row.element)
        if !selected { selected = await press(row.element, pid: pid) }
        guard selected else { return .couldNotPress }
        // Selecting a row navigates, and the play control is part of what navigation draws
        // — searching for it in the same runloop turn finds the previous page's.
        try? await Task.sleep(nanoseconds: 900_000_000)
        guard await pressPagePlay(pid: pid, registration: registration) else {
            return .couldNotPress
        }
        return wasGuess ? .playedAsGuess(row.name) : .played(row.name)
    }

    /// Press the control that starts what the player is currently showing.
    @discardableResult
    public static func pressPagePlay(
        pid: pid_t, registration: MediaSurfaceRegistration
    ) async -> Bool {
        guard let wanted = registration.schema.pagePlayLabel,
              let built = AXSnapshotBuilder.build(pid: pid, options: .exhaustive)
        else { return false }
        let folded = MediaSurfaceRegistration.folded(wanted)
        let transport = transportIDs(in: built.snapshot, registration: registration)

        var best: (id: AXNodeID, area: Double)?
        func walk(_ node: AXNodeSnapshot) {
            if !transport.contains(node.id),
               node.role.contains("Button"),
               let label = node.label,
               MediaSurfaceRegistration.folded(label) == folded,
               let frame = node.frame {
                let area = Double(frame.width * frame.height)
                if area > (best?.area ?? 0) { best = (node.id, area) }
            }
            for child in node.children { walk(child) }
        }
        for window in built.snapshot.windows {
            if let root = window.root { walk(root) }
        }
        guard let target = best, let element = built.elements[target.id] else { return false }
        return await press(element, pid: pid)
    }

    // MARK: - Shuffle

    /// Bring the player's shuffle mode to `desired`, pressing only if it is not already
    /// there.
    @discardableResult
    public static func pressShuffle(
        pid: pid_t, registration: MediaSurfaceRegistration, desired: Bool
    ) async -> Bool {
        guard registration.schema.shuffle != nil,
              let current = MediaSurfaceAX.read(
                pid: pid, registration: registration)?.isShuffling
        else { return false }
        guard current != desired else { return true }

        guard let built = AXSnapshotBuilder.build(pid: pid, options: .exhaustive)
        else { return false }
        let transport = transportIDs(in: built.snapshot, registration: registration)

        var control: AXUIElement?
        func walk(_ node: AXNodeSnapshot) {
            guard control == nil else { return }
            if transport.contains(node.id),
               node.role.contains("Button"),
               let label = node.label,
               registration.shuffleState(label) != nil,
               let element = built.elements[node.id] {
                control = element
                return
            }
            for child in node.children { walk(child) }
        }
        for window in built.snapshot.windows where control == nil {
            if let root = window.root { walk(root) }
        }

        guard let control else { return false }
        return await press(control, pid: pid)
    }

    // MARK: - The tree

    struct Row: Equatable {
        let name: String
        let element: AXUIElement
    }

    private struct RowsSnapshot {
        let outline: AXNodeSnapshot
        let elements: AXSnapshotBuilder.ElementTable
        let detail: AXSubtreeDetail
    }

    /// Locate the declared library outline and read its subtree once. Split
    /// out of `sidebarRows` so a re-walk after expanding folders is a second
    /// call to this, not a duplicated copy of the same search.
    private static func rowsSnapshot(
        pid: pid_t, registration: MediaSurfaceRegistration
    ) -> RowsSnapshot? {
        guard AXIsProcessTrusted(),
              let wanted = registration.schema.libraryLabel?.nilWhenEmpty,
              let built = AXSnapshotBuilder.build(pid: pid, options: .exhaustive)
        else { return nil }
        let folded = MediaSurfaceRegistration.folded(wanted)

        var outline: AXNodeSnapshot?
        func find(_ node: AXNodeSnapshot) {
            guard outline == nil else { return }
            if let label = node.label,
               MediaSurfaceRegistration.folded(label) == folded {
                outline = node
                return
            }
            for child in node.children { find(child) }
        }
        for window in built.snapshot.windows {
            if let root = window.root, outline == nil { find(root) }
        }
        guard let outline,
              let detail = AXDetailReader.read(
                subtree: outline, table: built.elements, budget: .probe)
        else { return nil }
        return RowsSnapshot(outline: outline, elements: built.elements, detail: detail)
    }

    /// A collapsed outline row's children are not materialized in the
    /// accessibility tree AT ALL until `kAXDisclosingAttribute` reads true —
    /// a playlist inside a collapsed folder is structurally invisible here,
    /// not merely filtered out by the section rule. A LEAF row (an ordinary
    /// playlist) also reads `disclosing == false` — it has nothing to
    /// disclose — but setting the attribute on it is a harmless no-op
    /// (`AXUIElementSetAttributeValue` fails silently when unsupported), so
    /// this attempts every row reading false rather than pre-filtering by
    /// settability, which costs the same one IPC round trip either way.
    /// Bounded — a sidebar's real folder count is small; this is not a
    /// license to expand an unbounded outline.
    private static let maxFoldersToExpand = 20

    @discardableResult
    private static func expandCollapsedRows(_ snapshot: RowsSnapshot) -> Bool {
        var expanded = 0
        func walk(_ node: AXNodeSnapshot) {
            guard expanded < maxFoldersToExpand else { return }
            if node.role == "AXRow", let element = snapshot.elements[node.id] {
                let disclosing = AX.attribute(element, kAXDisclosingAttribute as String) as? Bool
                if disclosing == false {
                    let result = AXUIElementSetAttributeValue(
                        element, kAXDisclosingAttribute as CFString, true as CFTypeRef)
                    if result == .success { expanded += 1 }
                }
            }
            for child in node.children { walk(child) }
        }
        walk(snapshot.outline)
        return expanded > 0
    }

    private static func collectRows(_ snapshot: RowsSnapshot) -> [Row] {
        var rows: [Row] = []
        func collect(_ node: AXNodeSnapshot) {
            if node.role == "AXRow" {
                // THE FIRST TEXT IN THE ROW IS ITS NAME. A row is a cell
                // holding an icon and a label; the icon carries no value, so
                // the first node that has one is the name.
                var name: String?
                func firstText(_ inner: AXNodeSnapshot) {
                    guard name == nil else { return }
                    if inner.role.contains("StaticText"),
                       let value = snapshot.detail.nodes[inner.id]?.textValue?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                       !value.isEmpty {
                        name = value
                        return
                    }
                    for child in inner.children { firstText(child) }
                }
                firstText(node)
                if let name, let element = snapshot.elements[node.id] {
                    rows.append(Row(name: name, element: element))
                }
            }
            for child in node.children { collect(child) }
        }
        collect(snapshot.outline)
        return rows
    }

    /// Every row of the declared library outline, with its live element.
    private static func sidebarRows(
        pid: pid_t, registration: MediaSurfaceRegistration
    ) async -> [Row]? {
        guard let first = rowsSnapshot(pid: pid, registration: registration) else { return nil }
        guard expandCollapsedRows(first) else { return collectRows(first) }
        // Something was expanded — its children only exist in a fresh walk.
        try? await Task.sleep(nanoseconds: 700_000_000)
        guard let second = rowsSnapshot(pid: pid, registration: registration) else {
            return collectRows(first)
        }
        return collectRows(second)
    }

    private static func transportIDs(
        in snapshot: AXAppSnapshot, registration: MediaSurfaceRegistration
    ) -> Set<AXNodeID> {
        let folded = MediaSurfaceRegistration.folded(registration.schema.transportLabel)
        var found: Set<AXNodeID> = []
        func collect(_ node: AXNodeSnapshot, inside: Bool) {
            let here = inside
                || MediaSurfaceRegistration.folded(node.label ?? "") == folded
            if here { found.insert(node.id) }
            for child in node.children { collect(child, inside: here) }
        }
        for window in snapshot.windows {
            if let root = window.root { collect(root, inside: false) }
        }
        return found
    }

    /// Select a sidebar row without needing it on screen. A library of 80+
    /// playlists overflows the visible viewport — most rows sit scrolled
    /// well outside the window's frame, so a coordinate click (`press`,
    /// below) lands on nothing and its fallback returns `true` unconditionally
    /// regardless: that mismatch is why `play()` used to report success while
    /// silently resuming whatever was already loaded. `AXSelected` is a pure
    /// state write over the AX channel, immune to scroll position — measured
    /// live against Apple Music's Sidebar: `AXUIElementSetAttributeValue`
    /// itself reports failure here even though the write visibly takes
    /// effect, so this verifies by reading the attribute back rather than
    /// trusting the call's own return code.
    private static func selectRow(_ element: AXUIElement) async -> Bool {
        _ = AXUIElementSetAttributeValue(
            element, kAXSelectedAttribute as CFString, true as CFTypeRef)
        try? await Task.sleep(nanoseconds: 500_000_000)
        return AX.attribute(element, kAXSelectedAttribute) as? Bool == true
    }

    /// AXPress first, then a real click at the midpoint — `PageElementActions`' proven
    /// ladder, for the reason it records: a control.
    @discardableResult
    static func press(_ element: AXUIElement, pid: pid_t) async -> Bool {
        if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
            try? await Task.sleep(nanoseconds: 350_000_000)
            return true
        }
        guard let frame = AX.frame(of: element),
              frame.width > 1, frame.height > 1,
              let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(
                mouseEventSource: source, mouseType: .leftMouseDown,
                mouseCursorPosition: CGPoint(x: frame.midX.rounded(), y: frame.midY.rounded()),
                mouseButton: .left),
              let up = CGEvent(
                mouseEventSource: source, mouseType: .leftMouseUp,
                mouseCursorPosition: CGPoint(x: frame.midX.rounded(), y: frame.midY.rounded()),
                mouseButton: .left)
        else { return false }
        // postToPid, never a global tap: the click belongs to the player that
        // owns the element and nothing else on screen should see it.
        down.postToPid(pid)
        up.postToPid(pid)
        try? await Task.sleep(nanoseconds: 250_000_000)
        return true
    }
}

private extension String {
    var nilWhenEmpty: String? { isEmpty ? nil : self }
}
