//
//  AXSnapshotBuilder.swift
//  MaryComputerUse
//
//  WHAT: Walk a process into AXAppSnapshot. IPC diet + messaging timeouts.
//  OUT:  AXAppSnapshot | ElementTable (live handles — see `build`)
//  PIN:  Native vs webArea budgets. Child cap before role — a web area past
//        an exhausted native budget is never discovered.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os

public enum AXSnapshotBuilder {

    public struct Options: Sendable {
        public var frontWindowBudget: AXTreeWalker.Budget
        public var backgroundWindowBudget: AXTreeWalker.Budget
        public var labelCap: Int
        /// The ceiling a `.webArea` subtree is walked against, replacing the window budget
        /// for page content.
        public var webAreaBudget: AXTreeWalker.Budget?
        // NO GAP SCAN. That sub-engine is deferred, and a scan whose only consumer does not
        // exist is one extra AX read per scroll area paying for nothing.

        public init(
            frontWindowBudget: AXTreeWalker.Budget = .init(maxDepth: 24, maxNodes: 1500),
            backgroundWindowBudget: AXTreeWalker.Budget = .init(maxDepth: 8, maxNodes: 300),
            labelCap: Int = 80,
            webAreaBudget: AXTreeWalker.Budget? = .init(maxDepth: 40, maxNodes: 6000)
        ) {
            self.frontWindowBudget = frontWindowBudget
            self.backgroundWindowBudget = backgroundWindowBudget
            self.labelCap = labelCap
            self.webAreaBudget = webAreaBudget
        }

        /// EXTRACTION, not live rendering. The defaults above are sized for a stream that
        /// must publish at a watchable cadence; this preset is for the one-shot
        /// `AXEngine.snapshot`.
        /// THE BROWSER'S OWN FURNITURE, AND NOT ONE NODE OF ITS PAGE.
        ///
        /// PIN: A SHELL READ HAS NO BUSINESS INSIDE THE PAGE, and it cost a
        /// navigation to prove it. Once the web-content tree is woken
        /// (`WebAXWakeup`) a browser window goes from about seventy nodes to
        /// several thousand, and `exhaustive` walked all of them to find a
        /// toolbar: the address-field lookup went from instant to ~700ms, was
        /// made twice per read and three times per navigation, and the detail
        /// read at the end of it began returning nil — so Mary answered "I
        /// couldn't find the address bar" about a field she had just typed into.
        /// `maxDepth: 0` on the web lane stops AT the web area: its own node is
        /// recorded, with its id, frame and URL — which is all a shell read ever
        /// wanted from it, and exactly what a browser declaring
        /// `urlSource: .webArea` reads — and nothing below it is walked.
        public static let shell = Options(
            frontWindowBudget: .init(maxDepth: 64, maxNodes: 20000),
            backgroundWindowBudget: .init(maxDepth: 64, maxNodes: 20000),
            labelCap: 200,
            webAreaBudget: .init(maxDepth: 0, maxNodes: 1))

        public static let exhaustive = Options(
            frontWindowBudget: .init(maxDepth: 64, maxNodes: 20000),
            backgroundWindowBudget: .init(maxDepth: 64, maxNodes: 20000),
            labelCap: 200,
            webAreaBudget: .init(maxDepth: 64, maxNodes: 50000))
    }

    /// What the web lane cost and found, aggregated across a walk's windows.
    /// Rides beside the snapshot as walk COST, never as content: it is what a
    /// monitor counts, and it never enters the published snapshot types.
    public struct WebWalkSummary: Sendable, Equatable {
        public var areaCount: Int = 0
        public var nodeCount: Int = 0
        public var truncated: Bool = false

        public init() {}

        mutating func absorb(_ tallies: LaneTallies) {
            areaCount += tallies.webAreaCount
            nodeCount += tallies.web.visited
            truncated = truncated || tallies.web.truncated
        }
    }

    /// One full walk of every standard window of `pid`. `nil` only when AX
    /// itself is untrusted or the process no longer exists — a target that
    /// merely answers slowly comes back truncated, never nil.
    public static func snapshot(pid: pid_t, options: Options = .init()) -> AXAppSnapshot? {
        build(pid: pid, options: options)?.snapshot
    }

    /// A walk this slow held whoever asked for it. Same channel as the turn
    /// clock, because that is the number it explains.
    static let walkLog = Logger(subsystem: "nyc.rao.mary", category: "turns")
    /// Below this a walk is ambient noise; at or above it, it is the turn.
    static let slowWalkSeconds: TimeInterval = 1.0

    /// The pure snapshot, the live-element side table the streamer's frame-only fast path
    /// needs (re-reading a known node's frame without a fresh structural walk), and the web
    /// lane's tally.
    /// The walk PLUS its live handles. A caller that must ACT on what it
    /// found needs the element behind an `AXNodeID`, and re-walking to find it
    /// again would race the user. The table is only as fresh as the walk:
    /// resolve, act, and drop it. Never store one.
    public static func build(
        pid: pid_t, options: Options = .init()
    ) -> (
        snapshot: AXAppSnapshot, elements: ElementTable, web: WebWalkSummary
    )? {
        guard AXIsProcessTrusted() else { return nil }
        guard let appName = NSRunningApplication(processIdentifier: pid)?.localizedName
        else { return nil }
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier

        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)

        let clock = ContinuousClock()
        let start = clock.now
        let rows = AXWindowRoster.windows(pid: pid, standardOnly: true)

        let recorder = ElementRecorder()
        var windows: [AXWindowSnapshot] = []
        var nodeCount = 0
        var web = WebWalkSummary()
        for (index, row) in rows.enumerated() {
            AXUIElementSetMessagingTimeout(row.element, 0.25)
            // Front window (index 0 — AX enumerates front-to-back) gets the deep budget;
            // every other window gets the shallow one.
            let budgets = LaneBudgets(
                native: index == 0 ? options.frontWindowBudget : options.backgroundWindowBudget,
                web: options.webAreaBudget)
            var tallies = LaneTallies()
            let root = buildNodeCore(
                from: row.element,
                lane: .native,
                depth: 0,
                source: .live(recorder: recorder),
                options: options,
                budgets: budgets,
                tallies: &tallies)
            nodeCount += tallies.native.visited + tallies.web.visited
            web.absorb(tallies)
            let windowID = AXNodeID(hashing: row.element)
            recorder.table[windowID] = row.element
            windows.append(AXWindowSnapshot(
                id: windowID,
                title: row.title,
                frame: row.frame,
                isMain: row.isMain,
                isMinimized: row.isMinimized,
                // A page truncated inside the web lane is still this
                // window's truncation — the render is honest but incomplete
                // either way, and the HUD separates the two.
                isTruncated: tallies.native.truncated || tallies.web.truncated,
                root: root,
                windowID: AXWindowIdentity.windowID(of: row.element)))
        }

        let duration = clock.now - start
        let snapshot = AXAppSnapshot(
            pid: pid,
            bundleID: bundleID,
            appName: appName,
            windows: windows,
            capturedAt: Date(),
            walkDuration: duration,
            nodeCount: nodeCount)
        // COUNTED, NOT ANNOUNCED. The ambient poll lands here roughly every
        // 1.5 seconds; an event per walk would bury the acts a watcher came
        // for, so the monitor keeps a tally and stays quiet.
        let seconds = TimeInterval(duration.components.seconds)
            + TimeInterval(duration.components.attoseconds) / 1e18
        ComputerUseMonitor.shared.noteSense(
            nodes: nodeCount,
            duration: seconds,
            truncated: windows.contains(where: \.isTruncated))
        // ...BUT A WALK THAT HELD A TURN SAYS SO. The tally above is the right
        // default for a 1.5s poll; a walk measured in SECONDS is not ambient
        // noise, it is the turn, and it was invisible until it was timed from
        // the caller's side. Threshold, not every walk — the poll stays quiet.
        if seconds >= slowWalkSeconds {
            walkLog.info(
                """
                slow walk — \(appName, privacy: .public) \
                \(Int(seconds * 1000), privacy: .public)ms · \
                \(nodeCount, privacy: .public) nodes · \
                \(Int(seconds * 1000) / max(nodeCount, 1), privacy: .public)ms/node\
                \(windows.contains(where: \.isTruncated) ? " · truncated" : "", privacy: .public)
                """)
        }
        return (snapshot, recorder.table, web)
    }

    /// `AXNodeID → AXUIElement`, scoped to one snapshot's lifetime. Package-
    /// internal: only the builder and the streamer ever see a live element.
    public typealias ElementTable = [AXNodeID: AXUIElement]

    /// A reference box for the side table, so the walk can record through a closure
    /// (`AXNodeSource.record`) — a closure cannot capture an `inout` dictionary, and
    /// threading a second `inout`.
    final class ElementRecorder {
        var table: ElementTable = [:]
    }

    // MARK: - The two lanes

    /// Which budget a node's subtree is charged against. `.web` is entered
    /// only at a `.webArea` node reached from `.native`, and never left.
    enum Lane: Sendable, Equatable {
        case native
        case web
    }

    struct LaneBudgets: Sendable {
        var native: AXTreeWalker.Budget
        var web: AXTreeWalker.Budget?

        /// Falls back to the native budget when web escalation is disabled,
        /// so a caller can ask for any lane's budget unconditionally.
        func budget(for lane: Lane) -> AXTreeWalker.Budget {
            switch lane {
            case .native: return native
            case .web: return web ?? native
            }
        }

        var escalates: Bool { web != nil }
    }

    struct WalkTally: Sendable, Equatable {
        var visited: Int = 0
        var truncated: Bool = false
    }

    struct LaneTallies: Sendable, Equatable {
        var native = WalkTally()
        var web = WalkTally()
        /// Every web area the walk saw, nested ones included — the count
        /// Clyde reports, not the number of escalations (which is only the
        /// top-level ones).
        var webAreaCount: Int = 0

        subscript(lane: Lane) -> WalkTally {
            get {
                switch lane {
                case .native: return native
                case .web: return web
                }
            }
            set {
                switch lane {
                case .native: native = newValue
                case .web: web = newValue
                }
            }
        }
    }

    /// Everything the core needs to read one node, injected. The live specialization is
    /// `AXNodeSource.live`; a test supplies a synthetic graph.
    struct AXNodeSource<Node> {
        var id: (Node) -> AXNodeID
        var role: (Node) -> String
        var subrole: (Node) -> String?
        /// The uncapped title→description ladder; the core applies
        /// `Options.labelCap`.
        var rawLabel: (Node) -> String?
        var frame: (Node) -> CGRect?
        var isEnabled: (Node) -> Bool
        var isFocused: (Node) -> Bool
        var children: (Node) -> [Node]
        var record: (AXNodeID, Node) -> Void
        /// `"AXContentSize"` — the gap scan's one extra read, consulted only after every
        /// cheaper gap predicate has already passed.
        var contentSize: (Node) -> CGSize?
    }

    /// Bounded recursive descent sharing one visited counter PER LANE, so the native lane's
    /// arithmetic matches `AXTreeWalker.walkCore` exactly (pinned together by
    /// `AXTreeWalkerTests`/`AXSnapshotBuildCoreTests`).
    static func buildNodeCore<Node>(
        from node: Node,
        lane: Lane,
        depth: Int,
        source: AXNodeSource<Node>,
        options: Options,
        budgets: LaneBudgets,
        tallies: inout LaneTallies
    ) -> AXNodeSnapshot {
        let id = source.id(node)
        source.record(id, node)
        let role = source.role(node)
        let category = AXNodeCategory.category(role: role)
        if category == .webArea { tallies.webAreaCount += 1 }

        // A web area reached from the native lane roots the web lane: it is charged to the
        // web budget, and its depth origin resets so `webAreaBudget.maxDepth` measures the
        // PAGE's nesting rather than the page's distance from the window.
        let escalating = lane == .native && category == .webArea && budgets.escalates
        let effectiveLane: Lane = escalating ? .web : lane
        let effectiveDepth = escalating ? 0 : depth
        let budget = budgets.budget(for: effectiveLane)

        tallies[effectiveLane].visited += 1

        // IPC diet: role + frame always; subrole/label only for categories that render one;
        // enabled/focused only for interactive nodes. (The frame read is hoisted above the
        // children loop so the gap scan below can reuse it.
        let subrole: String? = category == .other ? nil : source.subrole(node)
        let label: String? = category == .other
            ? nil : source.rawLabel(node).flatMap { capped($0, cap: options.labelCap) }
        let isEnabled: Bool = category == .interactive ? source.isEnabled(node) : true
        let isFocused: Bool = category == .interactive ? source.isFocused(node) : false
        let frame = source.frame(node)

        var children: [AXNodeSnapshot] = []
        var childrenComplete = true
        if effectiveDepth < budget.maxDepth {
            for child in source.children(node) {
                if tallies[effectiveLane].visited >= budget.maxNodes {
                    tallies[effectiveLane].truncated = true
                    childrenComplete = false
                    break
                }
                children.append(buildNodeCore(
                    from: child,
                    lane: effectiveLane,
                    depth: effectiveDepth + 1,
                    source: source,
                    options: options,
                    budgets: budgets,
                    tallies: &tallies))
            }
        } else if !source.children(node).isEmpty {
            tallies[effectiveLane].truncated = true
            childrenComplete = false
        }

        return AXNodeSnapshot(
            id: id,
            role: role,
            subrole: subrole,
            label: label,
            frame: frame,
            isEnabled: isEnabled,
            isFocused: isFocused,
            category: category,
            children: children)
    }

    /// A wireframe label is a glance, not a transcript.
    static func capped(_ text: String, cap: Int) -> String? {
        guard !text.isEmpty else { return nil }
        return text.count > cap ? String(text.prefix(cap)) + "…" : text
    }
}

extension AXSnapshotBuilder.AXNodeSource where Node == AXUIElement {

    /// The live specialization: every closure is one bounded AX read.
    static func live(recorder: AXSnapshotBuilder.ElementRecorder) -> Self {
        Self(
            id: { AXNodeID(hashing: $0) },
            role: { AX.string($0, kAXRoleAttribute) ?? "AXUnknown" },
            subrole: { AX.string($0, kAXSubroleAttribute) },
            rawLabel: { element in
                AX.string(element, kAXTitleAttribute).flatMap { $0.isEmpty ? nil : $0 }
                    ?? AX.string(element, kAXDescriptionAttribute)
                        .flatMap { $0.isEmpty ? nil : $0 }
            },
            frame: { AX.frame(of: $0) },
            isEnabled: { AX.attribute($0, kAXEnabledAttribute) as? Bool ?? true },
            isFocused: { AX.attribute($0, kAXFocusedAttribute) as? Bool ?? false },
            children: { AX.children($0) },
            record: { id, element in recorder.table[id] = element },
            contentSize: { AX.size($0, "AXContentSize") })
    }
}
