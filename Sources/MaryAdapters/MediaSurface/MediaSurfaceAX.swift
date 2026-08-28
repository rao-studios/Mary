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
        /// Nil when no node in the transport carried text.
        ///
        /// A REAL STATE, NOT A FAILED READ — a failed read returns no
        /// `Reading` at all. The player may be idle; it may also be playing
        /// and simply not exposing what. Measured: Apple Music publishes its
        /// LCD as two valued text nodes in most window states and as two
        /// EMPTY `AXUnknown` nodes in others, while still reporting itself as
        /// playing. Mary says "playing, but isn't saying what" there, because
        /// that is exactly what it knows.
        public var title: String?
        /// The line UNDER the title, as the player wrote it — commonly the
        /// artist and album joined by the application's own separator.
        ///
        /// KEPT WHOLE, NOT SPLIT. The separator is the player's choice and
        /// its meaning is not guaranteed: Apple Music writes
        /// "Enfant Sauvage — Petrichor", but a podcast player puts the show
        /// there and a radio stream puts nothing. Splitting on a dash would
        /// invent an artist and an album out of whatever happened to be
        /// either side of one, so Mary repeats the line the player wrote and
        /// lets it mean what it means.
        public var subtitle: String?
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

    /// WHERE THE TRANSPORT IS, by name first and by CONTENTS when the name
    /// is not there.
    ///
    /// The declared container is tried first because it is exact and cheap.
    /// The fallback exists because a container name is a fact about ONE VIEW:
    /// Apple Music's main window labels the group "Mini Player" and its
    /// full-screen Now Playing view gives the very same controls a group with
    /// no label at all. A name-only locator lost the player entirely whenever
    /// the user expanded it — reported, correctly but uselessly, as "the
    /// declared transport was not found".
    ///
    /// THE CONTENT RULE IS A PLAY BUTTON WITH A NEXT BESIDE IT. Neither alone
    /// is enough: a library page publishes a play button per row, thirty of
    /// them wearing the same word, and none of those has a skip control as a
    /// sibling. The SMALLEST such group wins, so a match cannot be the whole
    /// window merely because the window contains both somewhere.
    public static func transportID(
        in snapshot: AXAppSnapshot, registration: MediaSurfaceRegistration
    ) -> AXNodeID? {
        let wanted = MediaSurfaceRegistration.folded(registration.schema.transportLabel)
        var named: AXNodeID?
        func byName(_ node: AXNodeSnapshot) {
            guard named == nil else { return }
            if let label = node.label,
               MediaSurfaceRegistration.folded(label) == wanted {
                named = node.id
                return
            }
            for child in node.children { byName(child) }
        }
        for window in snapshot.windows where named == nil {
            if let root = window.root { byName(root) }
        }
        if let named { return named }

        guard let next = registration.schema.nextLabel.map(
            MediaSurfaceRegistration.folded) else { return nil }
        let playing = MediaSurfaceRegistration.folded(registration.schema.playingLabel)
        let paused = MediaSurfaceRegistration.folded(registration.schema.pausedLabel)

        var best: (id: AXNodeID, area: Double)?
        @discardableResult
        func scan(_ node: AXNodeSnapshot) -> (play: Bool, next: Bool) {
            var hasPlay = false
            var hasNext = false
            if let label = node.label.map(MediaSurfaceRegistration.folded) {
                if label == playing || label == paused { hasPlay = true }
                if label == next { hasNext = true }
            }
            for child in node.children {
                let found = scan(child)
                hasPlay = hasPlay || found.play
                hasNext = hasNext || found.next
            }
            if hasPlay, hasNext, let frame = node.frame {
                let area = Double(frame.width * frame.height)
                if area > 0, area < (best?.area ?? .greatestFiniteMagnitude) {
                    best = (node.id, area)
                }
            }
            return (hasPlay, hasNext)
        }
        for window in snapshot.windows {
            if let root = window.root { scan(root) }
        }
        return best?.id
    }

    /// Read the declared transport of one running player.
    public static func read(
        pid: pid_t, registration: MediaSurfaceRegistration
    ) -> Reading? {
        guard AXIsProcessTrusted() else { return nil }
        let wanted = MediaSurfaceRegistration.folded(registration.schema.transportLabel)

        guard let found = AXEngine.detail(pid: pid, select: { snapshot -> AXNodeID? in
            transportID(in: snapshot, registration: registration)
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

            // TITLE THEN SUBTITLE, IN TREE ORDER — which is the order they
            // are drawn in. Measured: the transport holds exactly two valued
            // text nodes, the taller one first (the track) and the shorter
            // one second (artist and album). Taking only the first was
            // discarding half the answer.
            // ANY NODE THAT CARRIES TEXT, not only `AXStaticText`. Measured:
            // the same two LCD nodes in the same two positions come back as
            // `AXStaticText` in one window state and `AXUnknown` in another,
            // so keying on the role dropped the title for no reason the user
            // could see. Buttons and sliders have labels rather than values,
            // so they do not collide with this.
            if node?.role.contains("Button") != true,
               let text = detail.textValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                if reading.title == nil { reading.title = text }
                else if reading.subtitle == nil { reading.subtitle = text }
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
