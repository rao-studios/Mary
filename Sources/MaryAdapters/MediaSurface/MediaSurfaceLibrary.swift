//
//  MediaSurfaceLibrary.swift
//  MaryAdapters
//
//  THE PLAYLISTS, AND THE BUTTON THAT STARTS ONE — the half of the port that
//  looked unreachable and was not.
//
//  WHAT THE FIRST CUT GOT WRONG, recorded because the correction is the
//  interesting part. Playlists were written off as Apple-Events-only, on the
//  reasoning that Bonnie reached them through `tell application "Music"` and
//  Mary has no scripting bridge. That confused the road with the
//  destination. The sidebar is an ordinary `AXOutline`: every playlist the
//  user owns is a row in it, and the names read exactly the way the track
//  title does — out of the static text's VALUE, through the detail lane.
//  Nothing about them needed an Apple Event either.
//
//  PLAYING IS TWO PRESSES, NOT ONE, and getting that wrong is why the first
//  version opened a song and left it sitting there. A Store URL navigates the
//  player to a page; it does not start it. The page's own Play button is what
//  starts it — and that button is NOT the transport's, though it wears the
//  same word. Pressing the transport instead resumes whatever was queued
//  before, which looks like success and plays the wrong thing.
//
//  SCOPE AND SIZE TELL THEM APART. Measured on a live player: the transport's
//  play is 36×38 inside the declared transport group; the page's is 132×38
//  outside it. So the rule is "outside the transport, largest wins" — stated
//  as a rule rather than a coordinate, because a coordinate is a fact about
//  one window at one size and this has to survive a resize.
//

import ApplicationServices
import Foundation
import MaryAmbient
import MaryFoundation

public enum MediaSurfaceLibrary {

    // MARK: - Reading the playlists

    /// The user's playlists, in sidebar order.
    ///
    /// Empty when the package declared no library, when the outline is not on
    /// screen, or when the section header is missing — all of which are
    /// "nothing to offer" rather than failures, and the caller says so.
    public static func playlists(
        pid: pid_t, registration: MediaSurfaceRegistration
    ) async -> [String] {
        guard let rows = await revealedRows(pid: pid, registration: registration) else {
            return []
        }
        return playlistNames(from: rows.map(\.name), registration: registration)
    }

    /// The library's rows, revealing the library first if it is not on screen.
    ///
    /// ONE RETRY, AND ONLY AFTER A MISS. A player already showing its sidebar
    /// is left exactly as the user arranged it; one that is not gets its
    /// declared reveal control pressed, once. A second failure is a real
    /// answer — the view did not come back — rather than a loop.
    private static func revealedRows(
        pid: pid_t, registration: MediaSurfaceRegistration
    ) async -> [Row]? {
        if let rows = sidebarRows(pid: pid, registration: registration), !rows.isEmpty {
            return rows
        }
        guard let reveal = registration.schema.libraryRevealLabel,
              await pressButton(labelled: reveal, pid: pid, registration: registration)
        else { return sidebarRows(pid: pid, registration: registration) }
        try? await Task.sleep(nanoseconds: 700_000_000)
        return sidebarRows(pid: pid, registration: registration)
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
        case noSuchPlaylist([String])
        /// Two playlists answered to the same spoken name. NAMED, NEVER
        /// GUESSED: starting one of two is a coin flip the user did not ask
        /// for, and the wrong one is audible immediately.
        case ambiguous([String])
        case noLibrary
        case couldNotPress
    }

    /// Select a playlist by name, then start it.
    ///
    /// MATCHED THE WAY IT WAS SPOKEN. An exact fold first, then
    /// `SpokenTitleMatcher` — the same ladder the prose lane uses to find a
    /// document, and for the same reason: a name arrives through speech
    /// recognition, so "dinner office playlist" has to reach "Dinner Office
    /// Playlist" and "gitas ballad" has to reach "Gita's Ballad" with its
    /// typographic apostrophe.
    public static func play(
        playlistNamed name: String, pid: pid_t, registration: MediaSurfaceRegistration
    ) async -> Outcome {
        guard let rows = await revealedRows(pid: pid, registration: registration) else {
            return .noLibrary
        }
        let offered = playlistNames(from: rows.map(\.name), registration: registration)
        guard !offered.isEmpty else { return .noLibrary }

        let resolved: String
        switch SpokenTitleMatcher.resolve(name, in: offered) {
        case .match(let title): resolved = title
        case .ambiguous(let titles): return .ambiguous(titles)
        case .none(let closest): return .noSuchPlaylist(closest)
        }
        guard let row = rows.first(where: { $0.name == resolved }) else {
            return .noSuchPlaylist(offered)
        }

        guard await press(row.element, pid: pid) else { return .couldNotPress }
        // THE PAGE HAS TO ARRIVE BEFORE ITS BUTTON CAN BE PRESSED. Selecting a
        // row navigates, and the play control is part of what navigation
        // draws — searching for it in the same runloop turn finds the
        // previous page's.
        try? await Task.sleep(nanoseconds: 900_000_000)
        guard await pressPagePlay(pid: pid, registration: registration) else {
            return .couldNotPress
        }
        return .played(row.name)
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

    // MARK: - The tree

    struct Row: Equatable {
        let name: String
        let element: AXUIElement
    }

    /// Every row of the declared library outline, with its live element.
    private static func sidebarRows(
        pid: pid_t, registration: MediaSurfaceRegistration
    ) -> [Row]? {
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
                       let value = detail.nodes[inner.id]?.textValue?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                       !value.isEmpty {
                        name = value
                        return
                    }
                    for child in inner.children { firstText(child) }
                }
                firstText(node)
                if let name, let element = built.elements[node.id] {
                    rows.append(Row(name: name, element: element))
                }
            }
            for child in node.children { collect(child) }
        }
        collect(outline)
        return rows
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

    /// AXPress first, then a real click at the midpoint — `PageElementActions`'
    /// proven ladder, for the reason it records: a control commonly advertises
    /// `AXPress` and does nothing with it, and a table row commonly offers no
    /// press action at all and only answers a click.
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
