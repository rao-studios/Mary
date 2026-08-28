//
//  AXSnapshotTestSupport.swift
//  BonniePluginTests
//
//  Shared fixture builders for tests that construct synthetic
//  `AXNodeSnapshot`/`AXAppSnapshot` trees without live AX. Pulled out of the
//  per-file private helpers `AXHitTestTests`/`AXSnapshotModelTests` each
//  already wrote, because `AXElementRosterTests` and
//  `ScreenElementResolverTests` both need multi-node, multi-window trees
//  neither of those smaller helpers builds.
//
//  NOT a singleton: each test owns its own `AXIDVendor` instance so tests
//  running in parallel never share mutable state — the same reason
//  `AXHitTestTests.nextRaw` was a private INSTANCE property, not a static.
//

import CoreGraphics
import Foundation
@testable import MaryPlugin

/// A monotonic `AXNodeID` source, one per test.
final class AXIDVendor {
    private var nextRaw: UInt = 1
    func next() -> AXNodeID {
        defer { nextRaw += 1 }
        return AXNodeID(raw: nextRaw)
    }
}

enum AXSnapshotTestSupport {
    static func node(
        _ ids: AXIDVendor,
        role: String = "AXStaticText",
        subrole: String? = nil,
        label: String? = nil,
        frame: CGRect? = nil,
        category: AXNodeCategory,
        isEnabled: Bool = true,
        isFocused: Bool = false,
        children: [AXNodeSnapshot] = []
    ) -> AXNodeSnapshot {
        AXNodeSnapshot(
            id: ids.next(), role: role, subrole: subrole, label: label, frame: frame,
            isEnabled: isEnabled, isFocused: isFocused, category: category, children: children)
    }

    static func window(
        _ ids: AXIDVendor,
        title: String = "Window",
        frame: CGRect? = nil,
        isMain: Bool = false,
        isMinimized: Bool = false,
        root: AXNodeSnapshot? = nil
    ) -> AXWindowSnapshot {
        AXWindowSnapshot(
            id: ids.next(), title: title, frame: frame, isMain: isMain,
            isMinimized: isMinimized, root: root)
    }

    static func app(
        _ windows: [AXWindowSnapshot],
        pid: pid_t = 1,
        bundleID: String? = "com.example.app",
        appName: String = "Example"
    ) -> AXAppSnapshot {
        AXAppSnapshot(
            pid: pid, bundleID: bundleID, appName: appName, windows: windows,
            capturedAt: Date(), walkDuration: .zero,
            nodeCount: windows.reduce(0) { $0 + ($1.root?.subtreeCount ?? 0) + 1 })
    }
}
