//
//  MediaSurfaceAX.swift
//  MaryAdapters
//
//  READING A PLAYER'S TRANSPORT through the same AX engine everything else
//  reads through — no Apple Events, no private framework, no polling daemon.
//
//  THE MEASUREMENT THIS IS BUILT ON. Against a live Apple Music the engine's
//  detail lane returned, from the declared transport subtree alone: the track
//  title as an `AXStaticText` value, the position as a slider at `0.062` of
//  `1.0`, and the words "Pause", "do not shuffle" and "repeat one" as button
//  labels. Everything `now_playing` reports is in that list. Nothing in it
//  needed an Automation grant.
//
//  WHY THE DETAIL LANE AND NOT THE SNAPSHOT. `AXNodeSnapshot` carries a
//  node's LABEL — its title or description — and a transport's track title
//  lives in its VALUE. Music publishes 119 `AXStaticText` nodes whose labels
//  are all empty; the first read of this tree found nothing and looked like
//  an application that simply does not expose what it is playing. The detail
//  lane (`AXEngine.detail`) is what reads values, and it is scoped to one
//  subtree precisely so this costs a transport-sized read rather than a
//  window-sized one.
//
//  SCOPED TO THE DECLARED CONTAINER, which is not an optimization. Apple
//  Music publishes ninety-five buttons; eight are the transport and most of
//  the rest are per-row Play buttons in the track table. Searching the window
//  for "a button labelled Play" finds a row in a playlist. The declared
//  container is what makes the question answerable at all.
//

import ApplicationServices
import Foundation
import MaryFoundation

public enum MediaSurfaceAX {

    /// What one look at a player's transport found.
    public struct Reading: Sendable, Equatable {
        /// Nil when no text node in the transport carried a value — the
        /// player is idle, or its LCD is empty. Distinct from a failed read,
        /// which returns no `Reading` at all.
        public var title: String?
        /// Nil when neither declared label was found: the read failed rather
        /// than the player being stopped.
        public var isPlaying: Bool?
        public var isShuffling: Bool?
        public var isRepeating: Bool?
        /// How far through, 0…1. Nil when no position slider was declared or
        /// none was found.
        public var position: Double?
        /// The element the reading came out of, for the behavioral record.
        public var element: AXElementRecord?
    }

    /// Read the declared transport of one running player.
    public static func read(
        pid: pid_t, registration: MediaSurfaceRegistration
    ) -> Reading? {
        guard AXIsProcessTrusted() else { return nil }
        let wanted = MediaSurfaceRegistration.folded(registration.schema.transportLabel)

        guard let found = AXEngine.detail(pid: pid, select: { snapshot -> AXNodeID? in
            var hit: AXNodeID?
            func walk(_ node: AXNodeSnapshot) {
                guard hit == nil else { return }
                if let label = node.label,
                   MediaSurfaceRegistration.folded(label) == wanted {
                    hit = node.id
                    return
                }
                for child in node.children { walk(child) }
            }
            for window in snapshot.windows {
                guard let root = window.root, hit == nil else { continue }
                walk(root)
            }
            return hit
        }) else { return nil }

        // THE SUBTREE IN TREE ORDER, so "the first text with a value" means
        // the leftmost one on screen — the title — rather than whichever the
        // detail dictionary happened to hash first. The detail lane returns
        // its nodes keyed by id; the SNAPSHOT is what remembers the order.
        var ordered: [AXNodeID] = []
        func collect(_ node: AXNodeSnapshot) {
            ordered.append(node.id)
            for child in node.children { collect(child) }
        }
        if let subtree = found.snapshot.subtree(withID: found.detail.rootID) {
            collect(subtree)
        }

        var reading = Reading()
        for id in ordered {
            guard let detail = found.detail.nodes[id] else { continue }
            let node = found.snapshot.subtree(withID: id)
            let label = node?.label ?? ""

            if reading.title == nil,
               node?.role.contains("StaticText") == true,
               let text = detail.textValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                reading.title = text
            }
            if reading.isPlaying == nil, !label.isEmpty {
                if registration.isPlayingLabel(label) { reading.isPlaying = true }
                else if registration.isPausedLabel(label) { reading.isPlaying = false }
            }
            if reading.isShuffling == nil, !label.isEmpty,
               let state = registration.shuffleState(label) {
                reading.isShuffling = state
            }
            if reading.isRepeating == nil, !label.isEmpty,
               let state = registration.repeatState(label) {
                reading.isRepeating = state
            }
            if reading.position == nil,
               let positionLabel = registration.schema.positionLabel,
               MediaSurfaceRegistration.folded(label)
                   == MediaSurfaceRegistration.folded(positionLabel),
               let value = detail.numericValue {
                // NORMALIZED AGAINST THE DECLARED MAXIMUM, because a slider's
                // range is the application's business: Music reports 0…1,
                // another player may report seconds. Dividing by the maximum
                // the element itself reports makes both mean the same thing.
                let maximum = detail.maximumValue ?? 1
                reading.position = maximum > 0 ? value / maximum : nil
            }
        }

        reading.element = found.snapshot
            .subtree(withID: found.detail.rootID)
            .flatMap { _ in ActedElementReader.focusedElement(pid: pid) }
        return reading
    }
}
