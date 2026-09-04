//
//  PagePerceptionPipeline.swift
//  MaryComputerUse
//
//  WHAT: How a page gets perceived — the lane list, and where a second lane joins.
//  IN:   BrowserEngine (never VisionPageReader directly)
//  OUT:  VisionPageReader.Reading
//  PIN:  THE STAGING SEAM. The browser engine asks the PIPELINE, not the reader, so
//        adding accessibility extraction later is one enum case and one function body
//        rather than a change at every call site. That indirection is the whole reason
//        this file exists, and it is worth one hop.
//        LANES ARE ORDERED BY EVIDENCE, NOT BY PREFERENCE. When two lanes describe the
//        same rectangle the one with a live element wins, because a row you can press
//        by name outranks a row you can only click at.
//

import CoreGraphics
import Foundation

/// Where a page's elements come from.
public enum PageReaderLane: String, Sendable, Equatable, CaseIterable {
    /// Pixels, through VisionAX. Works on any page in any browser, names nothing it
    /// cannot see, and hands back places to click rather than elements to press.
    case vision

    // TODO(browser-stage-3): case accessibility
    //
    // Publish `PageElementReader`'s web-area walk (Sight/PageElementReader.swift — the
    // walk is written and bounded; only `readWindowControls` is public today) as
    // `[PageElement]`, and merge it into the vision roster in `merge` below: a vision
    // row whose frame overlaps an AX element by IoU >= 0.6 is REPLACED by the AX row,
    // which carries a live handle and a real label; vision-only rows stay `.seen`.
    //
    // It needs two things this build does not have:
    //   1. The Chromium wake. Chrome builds no web-content AX tree until an assistive
    //      client announces itself, and until then the walk is EMPTY — indistinguishable
    //      from a page with nothing on it. The measured recipe is in the reference port
    //      (../Bonnie/Sources/BonniePlugin/AXEngine/Web/WebAXWakeup.swift): set BOTH
    //      AXManualAccessibility and AXEnhancedUserInterface on the MAIN pid, ignore
    //      both return codes (Chrome refuses one and half-refuses the other, then wakes
    //      ~2.3s later; Electron is the exact mirror), and poll
    //      `WebAreaLocator.firstWebArea` until it appears or ~6s passes.
    //   2. A gate on `WebContentHost.classify(pid:bundleID:) != .none`, so the wake
    //      signal is never sent to an app with no web content to wake — that classifier
    //      IS the blast radius for AXEnhancedUserInterface's relayout side effect.
    //
    // Until then the vision lane is the whole answer, and it says so rather than
    // returning an empty roster that reads like an empty page.
}

public enum PagePerceptionPipeline {

    /// Read a page through the lanes given, merged.
    public static func read(
        pid: pid_t,
        windowID: CGWindowID?,
        pageFrame: CGRect,
        intent: VisionPageReader.Intent,
        appName: String,
        windowTitle: String,
        lanes: [PageReaderLane] = [.vision],
        motionInterval: Duration = .milliseconds(180),
        previousFraction: Double? = nil,
        previousElapsed: TimeInterval? = nil
    ) async throws -> VisionPageReader.Reading {
        // ONE LANE TODAY, AND THE LIST IS STILL HONORED. A caller that asks for no lane
        // at all gets a refusal rather than a silently empty page.
        guard lanes.contains(.vision) else {
            throw VisionPageReader.Failure.visionUnavailable("no perception lane was requested")
        }
        return try await VisionPageReader.read(
            pid: pid,
            windowID: windowID,
            pageFrame: pageFrame,
            intent: intent,
            appName: appName,
            windowTitle: windowTitle,
            motionInterval: motionInterval,
            previousFraction: previousFraction,
            previousElapsed: previousElapsed)
    }

    /// How two lanes' rows become one roster.
    ///
    /// TODO(browser-stage-3): implement the IoU merge described on `PageReaderLane`.
    /// Today the accessibility lane produces nothing, so this is the identity — written
    /// as a named function anyway, because the day it stops being the identity should be
    /// a change to a body rather than a change to a shape.
    static func merge(
        _ vision: [AXScreenElement], _ accessibility: [PageElement]
    ) -> [AXScreenElement] {
        guard !accessibility.isEmpty else { return vision }
        return vision
    }

    /// Whether two frames describe the same thing. The rule the merge will use, written
    /// now because it is pure and testable without either lane.
    static func intersectionOverUnion(_ a: CGRect, _ b: CGRect) -> Double {
        let overlap = a.intersection(b)
        guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { return 0 }
        let intersection = Double(overlap.width * overlap.height)
        let union = Double(a.width * a.height) + Double(b.width * b.height) - intersection
        return union > 0 ? intersection / union : 0
    }

    /// Above this, two lanes are describing the same element.
    static let sameElementThreshold = 0.6
}
