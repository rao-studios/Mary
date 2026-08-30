//
//  ContributionSpans.swift
//  Mary
//
//  WHAT: Server char-offset spans → UI ranges + per-owner colors.
//  PIN:  Clamp with index(_:offsetBy:limitedBy:) (grapheme drift).
//

import MaryBrain
import SwiftUI

struct ContributionTextSpan: Identifiable {
    /// Stable id from owner + offsets (not UUID); rebuilt each body pass.
    let id: String
    let range: Range<String.Index>
    let owner: SeerContribution.Owner
    let color: Color

    /// `text` is the string `range` indexes into — the offsets it yields are
    /// what makes the id reproducible. Paragraph-local spans re-index against
    /// their own paragraph, so they identify consistently within it.
    init(
        range: Range<String.Index>, in text: String,
        owner: SeerContribution.Owner, color: Color
    ) {
        let lower = text.distance(from: text.startIndex, to: range.lowerBound)
        let upper = text.distance(from: text.startIndex, to: range.upperBound)
        self.id = "\(owner.id)#\(lower)-\(upper)"
        self.range = range
        self.owner = owner
        self.color = color
    }
}

/// djb2 over UTF-8. Swift's `hashValue` is seeded per process, so it cannot
/// anchor anything that has to look the same twice — a stroke seeded from it
/// redraws with a different shape on the next launch.
enum StableHash {
    static func of(_ string: String) -> Int {
        string.utf8.reduce(5381) { ($0 &* 33) &+ Int($1) }
    }
}

enum ContributionSpans {

    /// Five owner colors tuned to the Paper page (light-locked), anchored on
    /// maryGold; hashed by owner id so an owner keeps its color.
    static let palette: [Color] = [
        Color(red: 0.68, green: 0.56, blue: 0.38),  // mary gold
        Color(red: 0.22, green: 0.44, blue: 0.65),  // muted blue
        Color(red: 0.38, green: 0.55, blue: 0.38),  // sage green
        Color(red: 0.65, green: 0.40, blue: 0.55),  // muted mauve
        Color(red: 0.94, green: 0.56, blue: 0.68),  // warm pink
    ]

    static func paletteColor(for ownerID: String) -> Color {
        palette[abs(ownerID.hashValue) % palette.count]
    }

    /// Converts each owner's server offsets into clamped string ranges.
    static func makeSpans(text: String, contribution: SeerContribution) -> [ContributionTextSpan] {
        guard contribution.isAvailable else { return [] }
        return contribution.owners.flatMap { owner -> [ContributionTextSpan] in
            guard !owner.spans.isEmpty else { return [] }
            let color = paletteColor(for: owner.id)
            return owner.spans.compactMap { span -> ContributionTextSpan? in
                guard let range = span.range(in: text) else { return nil }
                return ContributionTextSpan(range: range, in: text, owner: owner, color: color)
            }
        }
    }
}
