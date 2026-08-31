//
//  AmbientWorld.swift
//  MaryAmbient
//
//  WHAT: The machine's entire standing state, hosted as one object.
//  OUT:  store (facts/selection/route) and snapshot() (this turn's packet)
//  PIN:  World = standing host. Snapshot = turn packet. One process store via .shared.
//

import Foundation

public final class AmbientWorld: @unchecked Sendable {
    public static let shared = AmbientWorld(store: .shared)

    public let store: AmbientContextStore

    public init(store: AmbientContextStore = AmbientContextStore()) {
        self.store = store
    }

    public func snapshot(at now: Date = Date()) -> Snapshot? {
        store.world(at: now)
    }
}

extension AmbientWorld {

    /// This turn's machine state — what is actually in front of the user.
    /// Faculty/channel is `attention`; taught place is `place`.
    public struct Snapshot: Sendable, Equatable {
        public var tier: AmbientWorldTier
        public var attention: AmbientAttention
        public var subject: String?
        /// Source app for a direct selection. Workspace worlds already name the plugin;
        /// `.applications` needs this to type back into the same frontmost surface.
        public var applicationID: String?
        public var key: AmbientKey?
        public var selectedText: String?
        /// Nearby text for a transform; never the write target.
        public var surroundingText: String?
        /// Source mutation capability. Nil for hover/activation (no text surface).
        public var selectionEditability: AmbientSelectionEditability?

        /// Where this turn's machine state lives. Bundle ids resolve to the taught
        /// registration; the applications host lane is never the identity.
        /// PIN: faculty `attention` remains the channel; place names the app.
        public var place: AmbientPlace {
            if let applicationID, !applicationID.isEmpty {
                let index = AmbientApplicationIndexProvider.current
                if let registration = index.registration(bundleID: applicationID)
                    ?? index.registration(id: applicationID) {
                    return registration.place
                }
                return .application(applicationID)
            }
            return .lane(attention)
        }
        /// How AX identified the text element. Canvas-descendant is enough to
        /// discuss the words, not to promise in-place replace (focus may be the canvas).
        public var selectionSourceEvidence: AmbientSelectionSourceEvidence?
        /// Payload recovered outside the AX source. Still an exact referent;
        /// routing must see this so it cannot become an in-place replace target.
        public var selectionPayloadRecovery: AmbientSelectionPayloadRecovery?
        public var capturedAt: Date
        public var freshFor: TimeInterval

        public init(
            tier: AmbientWorldTier,
            attention: AmbientAttention,
            subject: String? = nil,
            applicationID: String? = nil,
            key: AmbientKey? = nil,
            selectedText: String? = nil,
            surroundingText: String? = nil,
            selectionEditability: AmbientSelectionEditability? = nil,
            selectionSourceEvidence: AmbientSelectionSourceEvidence? = nil,
            selectionPayloadRecovery: AmbientSelectionPayloadRecovery? = nil,
            capturedAt: Date = Date(),
            freshFor: TimeInterval? = nil
        ) {
            self.tier = tier
            self.attention = attention
            self.subject = subject
            self.applicationID = applicationID
            self.key = key
            self.selectedText = selectedText
            self.surroundingText = surroundingText
            self.selectionEditability = selectionEditability
            self.selectionSourceEvidence = selectionSourceEvidence
            self.selectionPayloadRecovery = selectionPayloadRecovery
            self.capturedAt = capturedAt
            self.freshFor = freshFor ?? tier.freshFor
        }

        public init(selection fact: AmbientFact) {
            self.init(
                tier: .selection,
                attention: fact.attention,
                subject: fact.subject,
                applicationID: fact.applicationID,
                key: fact.key,
                selectedText: fact.content,
                surroundingText: fact.surroundingText,
                selectionEditability: nil,
                selectionSourceEvidence: nil,
                selectionPayloadRecovery: nil,
                capturedAt: fact.capturedAt,
                freshFor: fact.freshFor)
        }

        public func isFresh(at now: Date = Date()) -> Bool {
            let age = now.timeIntervalSince(capturedAt)
            return age >= 0 && age <= freshFor
        }

        public func matches(_ fact: AmbientFact) -> Bool {
            if let key { return fact.key == key }
            guard fact.attention == attention else { return false }
            return subject == nil || fact.subject == subject
        }

        public var isDirectReference: Bool { tier == .selection }
    }
}
