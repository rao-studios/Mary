//
//  MediaSurfaceLibrary.swift
//  MaryPlugin
//
//  WHAT: Playlists from AXOutline; play is page Play, not transport Play.
//  PIN:  Distinguish by scope+size (outside transport, largest wins).

import ApplicationServices
import Foundation
import MaryAmbient
import MaryComputerUse
import MaryFoundation
import os

public enum MediaSurfaceLibrary {

    /// WHAT THE LIBRARY LANE COST, on the media surface's own category — the
    /// way the web surface puts its acts, receipts and timings on `browsing`.
    /// `turns` is the turn circuit's (`TurnLog`), and a surface borrowing it
    /// makes the category stop saying who spoke. Nothing is lost by the
    /// scope: every category shares the subsystem, so
    /// `subsystem == "nyc.rao.mary"` still interleaves this with the turn
    /// clock it explains. This lane was the one media path the latency pass
    /// never covered, and it had no log line at all.
    private static let log = Logger(subsystem: "nyc.rao.mary", category: "media")

    /// Below this the lane is noise; at or above it, it is the turn.
    private static let slowLaneMilliseconds: UInt64 = 250

    /// `MARY_LANE_TIMING=1` also puts the line on stderr, because a probe is
    /// where this lane gets measured and a CLI tool's `os_log` info messages
    /// do not survive to `log show`. Same rung as
    /// `MARY_LIVE_SELECTION_COPY_PROBE`; off, this is os_log only.
    private static let echoesTiming =
        ProcessInfo.processInfo.environment["MARY_LANE_TIMING"] == "1"

    private static func note(
        _ what: String, since started: DispatchTime,
        fromReads: Int = 0, detail: String = ""
    ) {
        let ms = (DispatchTime.now().uptimeNanoseconds
            &- started.uptimeNanoseconds) / 1_000_000
        guard ms >= slowLaneMilliseconds || echoesTiming else { return }
        // ROUND TRIPS, NOT JUST MILLISECONDS. On a player whose AX server
        // answers between 7ms and 70ms depending on nothing this process
        // controls, the call count is the only number that compares two
        // traversals honestly. Zero unless `MARY_AX_COUNT=1`.
        let reads = AX.Accounting.enabled
            ? " · \(AX.Accounting.reads - fromReads) reads" : ""
        let suffix = (detail.isEmpty ? "" : " · " + detail) + reads
        log.info(
            """
            library — \(what, privacy: .public) \(ms, privacy: .public)ms\
            \(suffix, privacy: .public)
            """)
        if echoesTiming {
            FileHandle.standardError.write(
                Data("library — \(what) \(ms)ms\(suffix)\n".utf8))
        }
    }

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
        guard !Task.isCancelled else { return false }
        let folded = MediaSurfaceRegistration.folded(label)
        // FIRST MATCH WINS, so the search stops at it — the old whole-app
        // snapshot described every node in the player before this same
        // "first button wearing the label" rule was applied to the result.
        guard let element = AXElementFind.first(
            under: playerElement(pid: pid), budget: playerBudget,
            where: { candidate in
                candidate.role?.contains("Button") == true
                    && MediaSurfaceRegistration.folded(candidate.label ?? "") == folded
            })
        else { return false }
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

        // STOP MEANS STOP, NOT HURRY. Every remaining step is a real
        // Accessibility write; a cancelled caller (Stop, supersede) must not
        // race through them faster than an uncancelled one would.
        guard !Task.isCancelled else { return .couldNotPress }
        var selected = await selectRow(row.element)
        if !selected { selected = await press(row.element, pid: pid) }
        guard selected else { return .couldNotPress }
        // Selecting a row navigates, and the play control is part of what navigation draws
        // — searching for it in the same runloop turn finds the previous page's.
        guard !Task.isCancelled else { return .couldNotPress }
        try? await Task.sleep(nanoseconds: 900_000_000)
        guard !Task.isCancelled else { return .couldNotPress }
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
        guard let wanted = registration.schema.pagePlayLabel else { return false }
        let started = DispatchTime.now()
        let fromReads = AX.Accounting.reads
        let folded = MediaSurfaceRegistration.folded(wanted)
        // SKIP WHAT CANNOT HOLD THE ANSWER. The page Play button is never in
        // the library outline, and that outline is most of the player:
        // MEASURED on Apple Music, the sidebar subtree is ~427 of ~729 nodes,
        // and the old whole-app snapshot described every one of them to find
        // a button in the content pane.
        let skipped = [outlineElement(pid: pid, registration: registration)]
            .compactMap { $0 }

        // ALL, NOT FIRST: the rule is the LARGEST matching button, which
        // cannot be decided until every candidate has been seen.
        let candidates = AXElementFind.all(
            under: playerElement(pid: pid), budget: playerBudget, skipping: skipped,
            where: { candidate in
                candidate.role?.contains("Button") == true
                    && MediaSurfaceRegistration.folded(candidate.label ?? "") == folded
            })

        // ...AND NOT THE TRANSPORT'S OWN PLAY, which is the distinction this
        // function exists to make. Asked of the few candidates by walking
        // their parents, rather than of every node by building a set of the
        // transport's ids — the answer is the same and only the matches pay.
        let transportLabel = MediaSurfaceRegistration.folded(
            registration.schema.transportLabel)
        var best: (element: AXUIElement, area: Double)?
        for element in candidates {
            guard !isInside(element, labelled: transportLabel),
                  let frame = AX.frame(of: element) else { continue }
            let area = Double(frame.width * frame.height)
            if area > (best?.area ?? 0) { best = (element, area) }
        }
        note("page-play", since: started, fromReads: fromReads, detail: "\(candidates.count) candidates")
        guard let best else { return false }
        return await press(best.element, pid: pid)
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

        // The shuffle control lives INSIDE the transport, so the library
        // outline cannot hold it — skip it, for the same reason `pressPagePlay`
        // does, and ask the parent question only of the buttons that matched.
        let skipped = [outlineElement(pid: pid, registration: registration)]
            .compactMap { $0 }
        let transportLabel = MediaSurfaceRegistration.folded(
            registration.schema.transportLabel)
        let candidates = AXElementFind.all(
            under: playerElement(pid: pid), budget: playerBudget, skipping: skipped,
            where: { candidate in
                candidate.role?.contains("Button") == true
                    && registration.shuffleState(candidate.label ?? "") != nil
            })
        guard let control = candidates.first(where: {
            isInside($0, labelled: transportLabel)
        }) else { return false }
        return await press(control, pid: pid)
    }

    // MARK: - The tree

    struct Row: Equatable {
        let name: String
        let element: AXUIElement
    }

    // MARK: - Finding things without describing the player

    /// The ceiling the targeted searches run against. Deliberately generous —
    /// the saving here is NOT a tighter ceiling. A whole-player snapshot costs
    /// five to nine Accessibility round trips on every node because a snapshot
    /// must describe what it finds; a search costs role plus children on the
    /// nodes it passes and a label only where the role already matched, and it
    /// stops when it has the answer. MEASURED on Apple Music: 729 nodes at
    /// ~7ms each is ~5.1s for one snapshot, and `play_playlist` paid for two.
    private static let playerBudget = AXTreeWalker.Budget(maxDepth: 64, maxNodes: 20000)

    private static func playerElement(pid: pid_t) -> AXUIElement {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.5)
        return application
    }

    /// The declared library outline, found without describing the whole
    /// player. Breadth-first, so a container that sits near the top of the
    /// window is reached before the hundreds of rows hanging under it —
    /// measured on Apple Music, "Sidebar" is the FOURTH node a walk meets.
    private static func outlineElement(
        pid: pid_t, registration: MediaSurfaceRegistration
    ) -> AXUIElement? {
        guard AXIsProcessTrusted(),
              let wanted = registration.schema.libraryLabel?.nilWhenEmpty
        else { return nil }
        let folded = MediaSurfaceRegistration.folded(wanted)
        return AXElementFind.first(
            under: playerElement(pid: pid), budget: playerBudget,
            where: { MediaSurfaceRegistration.folded($0.label ?? "") == folded })
    }

    /// Is this node inside a container wearing `folded`?
    ///
    /// PIN: ASKED OF THE MATCHES, NOT OF THE TREE. The old shape built a set
    /// of every node id inside the transport, which meant walking the
    /// transport to answer a question about a handful of buttons. Walking a
    /// candidate's PARENTS costs a few reads each and gives the same answer.
    /// Bounded: a control's distance from its container is small, and an
    /// unbounded parent walk would not end on a cycle.
    private static func isInside(
        _ element: AXUIElement, labelled folded: String, hops: Int = 12
    ) -> Bool {
        guard !folded.isEmpty else { return false }
        var current: AXUIElement? = element
        var remaining = hops
        while let node = current, remaining > 0 {
            let label = AX.string(node, kAXTitleAttribute).flatMap { $0.isEmpty ? nil : $0 }
                ?? AX.string(node, kAXDescriptionAttribute).flatMap { $0.isEmpty ? nil : $0 }
            if let label, MediaSurfaceRegistration.folded(label) == folded { return true }
            current = AX.element(node, kAXParentAttribute)
            remaining -= 1
        }
        return false
    }

    // MARK: - Rows

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
    private static func expandCollapsedRows(_ rows: [AXUIElement]) -> Bool {
        var expanded = 0
        for element in rows {
            guard expanded < maxFoldersToExpand else { break }
            let disclosing = AX.attribute(element, kAXDisclosingAttribute as String) as? Bool
            if disclosing == false {
                let result = AXUIElementSetAttributeValue(
                    element, kAXDisclosingAttribute as CFString, true as CFTypeRef)
                if result == .success { expanded += 1 }
            }
        }
        return expanded > 0
    }

    /// Every row under the outline, and each row's name, in ONE traversal.
    ///
    /// PIN: ONE PASS, AND THE PASS IS THE WHOLE COST. The shape this replaced
    /// built a full `AXSnapshotBuilder` description of the player and then ran
    /// `AXDetailReader` over the outline — two traversals charging five to
    /// nine attributes a node, for a result that uses exactly two of them:
    /// which nodes are rows, and the first text value inside each. This reads
    /// role and children once per node and a value once per static text, and
    /// nothing else.
    ///
    /// PIN: AND IT IS ONE PASS FOR A REASON — a targeted search PER ROW was
    /// tried and MEASURED SLOWER than the snapshot it replaced (10-17s against
    /// ~6s): a hundred small searches re-read the subtrees the outer walk had
    /// already passed through. On this player the round trip is the cost, so
    /// the only thing that helps is making fewer of them, not shorter walks.
    ///
    /// Rows are recorded in PRE-ORDER — a disclosure folder before the rows it
    /// discloses — because `playlistNames` slices this list at a section
    /// header and order is the whole meaning of that slice.
    private static func readRows(under outline: AXUIElement) -> [Row] {
        var slots: [(element: AXUIElement, name: String?)] = []

        /// Returns the first static-text value anywhere in this subtree, which
        /// is what an enclosing row takes for its name.
        func visit(_ element: AXUIElement, depth: Int) -> String? {
            guard depth < rowTreeDepth, slots.count < maxRowsToRead else { return nil }
            let role = AX.string(element, kAXRoleAttribute)
            var slot: Int?
            if role == "AXRow" {
                slot = slots.count
                slots.append((element, nil))
            }
            var firstText: String?
            if role?.contains("StaticText") == true {
                firstText = AX.string(element, kAXValueAttribute)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilWhenEmpty
            }
            for child in AX.children(element) {
                let found = visit(child, depth: depth + 1)
                if firstText == nil { firstText = found }
            }
            if let slot, let firstText { slots[slot].name = firstText }
            return firstText
        }
        _ = visit(outline, depth: 0)

        return slots.compactMap { slot in
            slot.name.map { Row(name: $0, element: slot.element) }
        }
    }

    /// A sidebar is deep enough for nested disclosure and no deeper; a row's
    /// name is two hops down. Bounded so a pathological tree cannot stall.
    private static let rowTreeDepth = 32
    private static let maxRowsToRead = 2000

    /// Every row of the declared library outline, with its live element.
    private static func sidebarRows(
        pid: pid_t, registration: MediaSurfaceRegistration
    ) async -> [Row]? {
        let started = DispatchTime.now()
        let fromReads = AX.Accounting.reads
        guard let outline = outlineElement(pid: pid, registration: registration)
        else { return nil }
        let before = readRows(under: outline)
        guard expandCollapsedRows(before.map(\.element)) else {
            note("outline", since: started, fromReads: fromReads, detail: "\(before.count) rows")
            return before
        }
        // Something was expanded and its children exist only once the outline
        // has re-laid-out. THE OUTLINE ELEMENT IS STILL LIVE, so this re-reads
        // ITS subtree — the shape this replaced threw the whole snapshot away
        // and described the entire player a second time to see a few more rows.
        try? await Task.sleep(nanoseconds: 700_000_000)
        let after = readRows(under: outline)
        // Fewer rows than before the expand means the view was rebuilt under us
        // and these handles are stale — find the outline again.
        guard after.count >= before.count else {
            guard let fresh = outlineElement(pid: pid, registration: registration)
            else { return before }
            let rebuilt = readRows(under: fresh)
            note("outline", since: started, fromReads: fromReads, detail: "\(rebuilt.count) rows · rebuilt")
            return rebuilt
        }
        note("outline", since: started, fromReads: fromReads, detail: "\(after.count) rows · expanded")
        return after
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
        guard !Task.isCancelled else { return false }
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
