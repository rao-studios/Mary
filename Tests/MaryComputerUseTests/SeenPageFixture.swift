//
//  SeenPageFixture.swift
//  MaryComputerUseTests
//
//  WHAT: A page, built without a screenshot, for the seal to convert.
//  PIN:  BUILT THROUGH VisionAX'S OWN PIPELINE, not by hand. A hand-made map would prove
//        the converter works on a shape the builder never produces, which is the test
//        that passes while the lane is broken.
//        THE ONE OTHER FILE THAT MAY IMPORT VisionAX. It is a test fixture, outside
//        Sources/, so the seal test does not see it — and it exists so the seal itself
//        can be tested at all.
//

import CoreGraphics
import Foundation
import VisionAX

enum SeenPageFixture {

    typealias Row = (label: String, role: String?, frame: CGRect, affordance: String)

    static func scene(
        pageOrigin: CGPoint,
        pixelsPerPoint: Double,
        rows: [Row],
        named: Bool = true,
        overlay: CGRect? = nil
    ) -> VisionScene {
        let bounds = CGRect(x: 0, y: 0, width: 1_000, height: 900)
        var children: [AXNodeSnapshot] = []
        var runs: [TextRun] = []
        var labels: [AXNodeID: RegionLabel] = [:]
        var identifier: UInt = 2

        if let overlay {
            children.append(AXNodeSnapshot(
                id: AXNodeID(raw: identifier), role: "AXGroup", frame: overlay,
                category: .container))
            identifier += 1
        }
        for row in rows {
            let id = AXNodeID(raw: identifier)
            children.append(AXNodeSnapshot(
                id: id,
                role: row.role ?? VisionAX.regionRole,
                frame: row.frame,
                category: row.role.map { AXNodeCategory.category(role: $0) } ?? .other))
            if row.role != nil {
                labels[id] = RegionLabel(
                    classIndex: 1, role: row.role ?? "", confidence: 0.9)
            }
            identifier += 1
            if named {
                runs.append(TextRun(
                    string: row.label,
                    frame: row.frame.insetBy(dx: 4, dy: 8),
                    confidence: 0.9))
            }
        }

        let root = AXNodeSnapshot(
            id: AXNodeID(raw: 1), role: VisionAX.windowRole, frame: bounds,
            category: .window, children: children)
        let detection = VisionDetection(
            window: AXWindowSnapshot(
                id: AXNodeID(raw: 1), title: "A Page", frame: bounds,
                isMain: true, isTruncated: false, root: root),
            options: .standard,
            nodeCount: children.count + 1,
            contourCount: children.count,
            duration: .zero,
            labels: named ? labels : nil)

        return VisionScene(
            detection: detection,
            projection: ScreenProjection(origin: pageOrigin, pixelsPerPoint: pixelsPerPoint),
            regionOfInterest: bounds,
            imageBounds: bounds,
            text: runs)
    }
}
