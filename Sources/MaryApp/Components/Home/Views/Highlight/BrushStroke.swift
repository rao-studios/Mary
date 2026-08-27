//
//  BrushStroke.swift
//  Mary
//
//  A hand-painted highlight stroke with seeded randomness — unique per
//  segment, stable across redraws. Verbatim port from Sis
//  (Components/Chat/Views/Highlight/HighlightHelpers.swift).
//

import SwiftUI

struct BrushStroke: Shape {
    var seed: Int

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var rng = SeededRNG(seed: seed)

        let steps = 2
        let stepWidth = rect.width / CGFloat(steps)
        let wobble: CGFloat = rect.height * 0.25
        let skewY: CGFloat = CGFloat(rng.next(in: -0.8...0.8))

        // Build top edge (left → right)
        var topPoints: [CGPoint] = []
        for i in 0...steps {
            let x = rect.minX + stepWidth * CGFloat(i)
            let baseY = rect.minY + skewY * (CGFloat(i) / CGFloat(steps) - 0.5)
            let jitter = CGFloat(rng.next(in: -Double(wobble)...Double(wobble * 0.4)))
            topPoints.append(CGPoint(x: x, y: baseY + jitter))
        }

        // Build bottom edge (left → right)
        var bottomPoints: [CGPoint] = []
        for i in 0...steps {
            let x = rect.minX + stepWidth * CGFloat(i)
            let baseY = rect.maxY + skewY * (CGFloat(i) / CGFloat(steps) - 0.5)
            let jitter = CGFloat(rng.next(in: -Double(wobble * 0.4)...Double(wobble)))
            bottomPoints.append(CGPoint(x: x, y: baseY + jitter))
        }

        // Taper the brush tips
        let taper: CGFloat = rect.height * 0.22
        topPoints[0].y += taper
        bottomPoints[0].y -= taper
        topPoints[steps].y += taper * 0.65
        bottomPoints[steps].y -= taper * 0.65

        // Draw top edge with quadratic curves
        path.move(to: topPoints[0])
        for i in 1..<topPoints.count {
            let prev = topPoints[i - 1]
            let curr = topPoints[i]
            let midX = (prev.x + curr.x) / 2
            path.addQuadCurve(to: curr, control: CGPoint(x: midX, y: prev.y))
        }

        // Draw bottom edge in reverse
        let revBottom = Array(bottomPoints.reversed())
        path.addLine(to: revBottom[0])
        for i in 1..<revBottom.count {
            let prev = revBottom[i - 1]
            let curr = revBottom[i]
            let midX = (prev.x + curr.x) / 2
            path.addQuadCurve(to: curr, control: CGPoint(x: midX, y: prev.y))
        }

        path.closeSubpath()
        return path
    }
}

/// Deterministic RNG so brushstrokes stay stable across redraws.
struct SeededRNG {
    private var state: UInt64

    init(seed: Int) {
        state = UInt64(bitPattern: Int64(seed &+ 0x9E3779B97F4A7C1))
    }

    mutating func nextRaw() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z = z ^ (z >> 31)
        return z
    }

    mutating func next(in range: ClosedRange<Double>) -> Double {
        let raw = nextRaw()
        let normalized = Double(raw) / Double(UInt64.max)
        return range.lowerBound + normalized * (range.upperBound - range.lowerBound)
    }
}
