//
//  ScreenLookFaculty.swift
//  MaryBrain
//
//  WHAT: One ephemeral look at what the user sees.
//  IN:   ScreenRegionCapture + Sewn vision (both injected)
//  OUT:  description on the outcome summary; image bytes die with the call
//  PIN:  Never archived, never logged.
//
import MaryPlugin
import Foundation
import MaryComputerUse

public enum ScreenLookFaculty {

    /// What the capture saw, minus nothing: the bytes ride here and die here.
    public struct Sight: Sendable {
        public let appTitle: String
        /// The looked-at app's bundle identifier — STRUCTURAL.
        public let bundleID: String?
        public let windowTitle: String?
        /// Spoken provenance ("the region under your cursor", "the whole
        /// window") so a fallback is never disguised as precision.
        public let provenanceLabel: String
        public let imageData: Data
        public let mediaType: String

        public init(
            appTitle: String,
            bundleID: String? = nil,
            windowTitle: String?,
            provenanceLabel: String,
            imageData: Data,
            mediaType: String
        ) {
            self.appTitle = appTitle
            self.bundleID = bundleID
            self.windowTitle = windowTitle
            self.provenanceLabel = provenanceLabel
            self.imageData = imageData
            self.mediaType = mediaType
        }
    }

    /// `home` files the successful look as ambient evidence — glance stamp + a fact in the looked-at realm
    public static func look(
        query: String?,
        capture: @Sendable () async throws -> Sight,
        describe: @Sendable (Sight, String?) async throws -> String,
        home: (@Sendable (Sight, String) -> Bool)? = nil
    ) async -> SkillOutcome {
        let sight: Sight
        do {
            sight = try await capture()
        } catch let failure as ScreenRegionCapture.Failure {
            return refusal(for: failure)
        } catch {
            return SkillOutcome(
                ok: false,
                summary: "I couldn't get a look at the screen just now.",
                status: .failed,
                archivePolicy: .none)
        }

        do {
            let description = try await describe(sight, query)
            let place = sight.windowTitle.map { "\(sight.appTitle) — \($0)" }
                ?? sight.appTitle
            let deposited = home?(sight, description) ?? false
            return SkillOutcome(
                ok: true,
                summary: "Looked at \(place) (\(sight.provenanceLabel)): \(description)",
                archivePolicy: .none,
                ambientDeposited: deposited)
        } catch let error as SewnVisionError {
            return visionFailure(for: error)
        } catch {
            return SkillOutcome(
                ok: false,
                summary: "I looked, but my vision service isn't reachable right now, so I can't describe it.",
                status: .failed,
                archivePolicy: .none)
        }
    }

    // MARK: - Honest sentences

    private static func refusal(for failure: ScreenRegionCapture.Failure) -> SkillOutcome {
        switch failure {
        case .accessibilityDenied:
            return SkillOutcome(
                ok: false,
                summary: "I can't find what you're looking at — Mary doesn't have the Accessibility permission.",
                status: .blocked,
                archivePolicy: .none)
        case .screenRecordingUnavailable:
            return SkillOutcome(
                ok: false,
                summary: "I can't see the screen — Mary doesn't have the Screen Recording permission.",
                status: .blocked,
                archivePolicy: .none)
        case .nothingFrontmost, .windowUnavailable:
            return SkillOutcome(
                ok: false,
                summary: "There's no readable window in front for me to look at right now.",
                status: .failed,
                archivePolicy: .none)
        }
    }

    private static func visionFailure(for error: SewnVisionError) -> SkillOutcome {
        switch error {
        case .notAuthenticated:
            return SkillOutcome(
                ok: false,
                summary: "I looked, but I'm not signed in to my vision service, so I can't describe it.",
                status: .failed,
                archivePolicy: .none)
        case .http, .unreachable, .emptyDescription:
            return SkillOutcome(
                ok: false,
                summary: "I looked, but my vision service isn't reachable right now, so I can't describe it.",
                status: .failed,
                archivePolicy: .none)
        }
    }
}
