//
//  MediaSurfaceAX.swift
//  MaryPlugin
//
//  WHAT: Read a player's transport via AXEngine.detail on the declared subtree.
//  PIN:  Title lives in VALUE, not snapshot LABEL. Scope is the declared container.

import ApplicationServices
import Foundation
import MaryFoundation

public enum MediaSurfaceAX {

    /// What one look at a player's transport found.
    public struct Reading: Sendable, Equatable {
        /// Nil when no node in the transport carried text. A REAL STATE, NOT A FAILED READ
        /// — a failed read returns no `Reading` at all.
        public var title: String?
        /// The line UNDER the title, as the player wrote it — commonly the artist and album
        /// joined by the application's own separator.
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

    /// WHERE THE TRANSPORT IS, by name first and by CONTENTS when the name is not there.
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

        // Subtree in tree order: first valued text = leftmost on screen (title).
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

            // TITLE THEN SUBTITLE, IN TREE ORDER — which is the order they are drawn in.
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
                // NORMALIZED AGAINST THE DECLARED MAXIMUM, because a slider's range is the
                // application's business: Music reports 0…1, another player may report
                // seconds.
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
