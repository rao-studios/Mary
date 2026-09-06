//
//  PagePlayerDerivation.swift
//  MaryComputerUse
//
//  WHAT: Where the page's picture is, and which rows are drawn OVER it.
//  IN:   [PageRow] + the page frame, at the seal
//  OUT:  VisionPageReader (the seal) / PageListing (the offline chain) / the
//        browsing engine's reveal
//  PIN:  SHAPE AND SIZE, NEVER A SITE. A player reads as a large image-like
//        row — at least a fifth of the page, wider than it is tall the way video
//        is. A small pressable row INSIDE that rectangle is something drawn over
//        the picture: a skip control, a card, a prompt. That is the same fact an
//        overlay group carries (`RowFacts.inOverlay`), decided from geometry the
//        picture lane already reads, so "skip the ad" reaches a button over the
//        video the way "accept" reaches a button over a dimmed page — through the
//        one router, with no verb of its own. The player's transport is not an
//        overlay: it is the thin band along the bottom edge, and it is excluded
//        by shape, not by name.
//

import CoreGraphics
import Foundation

public enum PagePlayerDerivation {

    /// How much of the page a row must cover before it can be the picture.
    public static let playerAreaShare: CGFloat = 0.2
    /// The shape of video: wider than tall, and not a banner.
    public static let playerMinimumAspect: CGFloat = 1.2
    public static let playerMaximumAspect: CGFloat = 3.0
    /// A row over the picture is small next to it — a control, not a second picture.
    static let overlayAreaShare: CGFloat = 0.12
    /// The transport band along the bottom edge, as a share of the player's height.
    static let transportBandShare: CGFloat = 0.18

    /// The picture on the page, when the reading held one: the largest
    /// image-like row of video's shape. Nil on a page with no such row.
    public static func playerFrame(rows: [PageRow], pageFrame: CGRect) -> CGRect? {
        let area = pageFrame.width * pageFrame.height
        guard area > 0 else { return nil }
        return rows
            .filter { row in
                let frame = row.frame
                guard frame.width > 0, frame.height > 0 else { return false }
                guard frame.width * frame.height >= area * playerAreaShare else { return false }
                let aspect = frame.width / frame.height
                return aspect >= playerMinimumAspect && aspect <= playerMaximumAspect
            }
            .max { ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height) }?
            .frame
    }

    /// The rows drawn over the picture, marked `inOverlay`. Everything else is
    /// returned as it was; a page with no picture is untouched.
    public static func markOverlays(rows: [PageRow], pageFrame: CGRect) -> [PageRow] {
        guard let player = playerFrame(rows: rows, pageFrame: pageFrame) else { return rows }
        let playerArea = player.width * player.height
        let transportTop = player.maxY - player.height * transportBandShare
        return rows.map { row in
            guard row.affordance == .press,
                  player.contains(row.frame),
                  row.frame.width * row.frame.height <= playerArea * overlayAreaShare,
                  // The transport lives along the bottom edge; a control above
                  // that band is over the picture itself.
                  row.frame.midY < transportTop
            else { return row }
            var marked = row
            marked.facts.insert(.inOverlay)
            return marked
        }
    }
}
