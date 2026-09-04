//
//  VisionPageReader.swift
//  MaryComputerUse
//
//  WHAT: What is on a page, read from its pixels. THE ONLY FILE THAT IMPORTS VisionAX.
//  IN:   WindowPixels + VisionAX
//  OUT:  Reading — AXScreenElement rows and a MediaControlReading, in screen points
//  PIN:  THE SEAL IS HERE. VisionAX replicates Mary's AX type names (AXNodeSnapshot,
//        AXScreenElement, AXNodeCategory), so a second importer anywhere in the module
//        would make every use of those names ambiguous. Everything crosses at this file
//        and leaves as Mary's own types; VisionAXSealTests reads the sources to keep it
//        that way.
//        DETECTION RUNS OFF THE CALLER'S TASK. The engine is synchronous and
//        CPU-bound — a page's worth of Canny is tens of milliseconds — so it goes to a
//        detached task rather than blocking whatever actor asked.
//        NO CLASSIFIER IS NOT NO ANSWER. The media lane needs no model at all (the
//        glyphs are drawn, not learned), so a machine without one can still pause a
//        video; only the element lane refuses, and it refuses by name.
//

import CoreGraphics
import Foundation
import VisionAX
import os

public enum VisionPageReader {

    /// What the caller wants out of the page. Each lane costs real time.
    public enum Intent: String, Sendable, Equatable {
        /// The transport. Two captures, no classifier, no text beyond the clock.
        case media
        /// The page's elements, named by the classifier.
        case elements
    }

    public struct Reading: Sendable {
        /// Rows in reading order, screen points, `provenance == .seen`.
        public var elements: [AXScreenElement]
        public var media: MediaControlReading?
        /// The region that was read, in screen points.
        public var pageFrame: CGRect
        public var pixelsPerPoint: Double
        public var duration: Duration
        /// Whether a role classifier ran. False means every element is an unnamed box.
        public var classified: Bool

        public init(
            elements: [AXScreenElement] = [],
            media: MediaControlReading? = nil,
            pageFrame: CGRect,
            pixelsPerPoint: Double,
            duration: Duration = .zero,
            classified: Bool = false
        ) {
            self.elements = elements
            self.media = media
            self.pageFrame = pageFrame
            self.pixelsPerPoint = pixelsPerPoint
            self.duration = duration
            self.classified = classified
        }
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case visionUnavailable(String)
        case classifierUnavailable
        case pageNotVisible
        case capture(String)

        public var errorDescription: String? {
            switch self {
            case .visionUnavailable(let detail): return "The vision engine failed: \(detail)"
            case .classifierUnavailable:
                return "No region classifier is installed, so I can't name what's on the page."
            case .pageNotVisible: return "I can't see the page to read it."
            case .capture(let detail): return detail
            }
        }
    }

    /// One look at a page.
    ///
    /// `previousFraction` and `previousElapsed` come from an EARLIER reading; supplying
    /// them is what lets the engine say a video advanced rather than merely that it has
    /// a progress bar.
    public static func read(
        pid: pid_t,
        windowID: CGWindowID?,
        pageFrame: CGRect,
        intent: Intent,
        appName: String,
        windowTitle: String,
        motionInterval: Duration = .milliseconds(180),
        previousFraction: Double? = nil,
        previousElapsed: TimeInterval? = nil
    ) async throws -> Reading {
        guard pageFrame.width > 8, pageFrame.height > 8 else {
            ComputerUseMonitor.shared.note(
                lane: .sight, refused: "perceive", pid: pid, reason: .pageNotVisible)
            throw Failure.pageNotVisible
        }
        let session: VisionSession
        do {
            session = try VisionSession.shared()
        } catch {
            let detail = String(describing: error)
            ComputerUseMonitor.shared.note(
                lane: .sight, refused: "perceive", pid: pid,
                reason: .visionUnavailable(detail))
            throw Failure.visionUnavailable(detail)
        }
        if intent == .elements, session.classifier == nil {
            ComputerUseMonitor.shared.note(
                lane: .sight, refused: "perceive", pid: pid, reason: .classifierUnavailable)
            throw Failure.classifierUnavailable
        }

        // MEDIA NEEDS TWO FRAMES, AND THEY MUST BE THE SAME WINDOW. A capture between
        // them that landed on a different window would report the difference between
        // two pictures as a video playing.
        var earlier: CGImage?
        if intent == .media {
            let first = try await capture(pid: pid, windowID: windowID, pageFrame: pageFrame)
            earlier = WindowPixels.crop(first, to: pageFrame)
            try? await Task.sleep(for: motionInterval)
        }
        let frame = try await capture(pid: pid, windowID: windowID, pageFrame: pageFrame)
        guard let cropped = WindowPixels.crop(frame, to: pageFrame) else {
            ComputerUseMonitor.shared.note(
                lane: .sight, refused: "perceive", pid: pid, reason: .pageNotVisible)
            throw Failure.pageNotVisible
        }

        let projection = ScreenProjection(
            origin: pageFrame.origin, pixelsPerPoint: frame.pixelsPerPoint)
        let lanes: VisionLanes = intent == .media ? [.media, .text] : [.regions, .text]
        let classifier = intent == .elements ? session.classifier : nil
        let engine = session.engine
        let previous = earlier

        let started = ContinuousClock.now
        let scene: VisionScene
        do {
            scene = try await Task.detached(priority: .userInitiated) {
                try engine.perceive(
                    image: cropped,
                    projection: projection,
                    classifier: classifier,
                    lanes: lanes,
                    previous: previous,
                    title: windowTitle,
                    previousFraction: previousFraction,
                    previousElapsed: previousElapsed)
            }.value
        } catch {
            let detail = String(describing: error)
            ComputerUseMonitor.shared.note(
                lane: .sight, refused: "perceive", pid: pid,
                reason: .visionUnavailable(detail))
            throw Failure.visionUnavailable(detail)
        }
        let elapsed = started.duration(to: ContinuousClock.now)

        let media = scene.media.map {
            reading(from: $0, scene: scene, pageFrame: pageFrame, capturedAt: scene.capturedAt)
        }
        let elements = intent == .elements
            ? rows(from: scene, pid: pid, appName: appName, windowTitle: windowTitle)
            : []

        ComputerUseMonitor.shared.note(
            lane: .sight, act: "perceive", pid: pid,
            detail: "\(intent.rawValue) \(elements.count) elements"
                + (media.map { " · \($0.others.count) controls · \($0.playback.rawValue)" } ?? "")
                + " · \(elapsed)")
        return Reading(
            elements: elements,
            media: media,
            pageFrame: pageFrame,
            pixelsPerPoint: frame.pixelsPerPoint,
            duration: elapsed,
            classified: classifier != nil)
    }

    private static func capture(
        pid: pid_t, windowID: CGWindowID?, pageFrame: CGRect
    ) async throws -> WindowPixels.Frame {
        do {
            return try await WindowPixels.capture(pid: pid, windowID: windowID)
        } catch let failure as WindowPixels.Failure {
            throw Failure.capture(failure.localizedDescription)
        }
    }

    // MARK: - Crossing the seam

    /// VisionAX's pixel-space detection as Mary's screen-space reading.
    ///
    /// PIN: EVERY FRAME IS PROJECTED HERE, AND NOWHERE ELSE. A detection speaks in the
    /// captured image's pixels; a click needs global screen points. Handing a pixel rect
    /// on as if it were a point rect is the bug this crossing exists to prevent — it was
    /// measured aiming a click 750pt away from the button, on the wrong display.
    static func reading(
        from detection: MediaControlDetection, scene: VisionScene,
        pageFrame: CGRect, capturedAt: Date
    ) -> MediaControlReading {
        func control(_ source: MediaControlDetection.Control?) -> MediaControlReading.Control? {
            source.map {
                MediaControlReading.Control(
                    frame: scene.projection.screenRect($0.frame),
                    glyph: glyph($0.glyph),
                    confidence: $0.confidence)
            }
        }
        return MediaControlReading(
            pageFrame: pageFrame,
            controlsVisible: detection.controlsVisible,
            playback: playback(detection.playback),
            witnesses: detection.witnesses,
            playPause: control(detection.playPause),
            volume: control(detection.volume),
            fullscreen: control(detection.fullscreen),
            centerGlyph: control(detection.centerGlyph),
            others: detection.controls.compactMap { control($0) },
            progress: detection.progress.map {
                MediaControlReading.Progress(
                    frame: scene.projection.screenRect($0.frame), fraction: $0.fraction)
            },
            elapsed: detection.elapsed,
            duration: detection.duration,
            capturedAt: capturedAt)
    }

    private static func playback(_ value: MediaControlDetection.Playback) -> MediaControlReading.Playback {
        switch value {
        case .playing: return .playing
        case .paused: return .paused
        case .unknown: return .unknown
        }
    }

    /// Vocabulary conversion, spelled out. Both enums are string-backed, so a rawValue
    /// hop would compile and silently answer `.none` the day either one is extended.
    private static func glyph(_ value: MediaGlyph) -> MediaControlReading.Glyph {
        switch value {
        case .none: return .none
        case .play: return .play
        case .pause: return .pause
        case .replay: return .replay
        case .volume: return .volume
        case .muted: return .muted
        case .fullscreen: return .fullscreen
        case .exitFullscreen: return .exitFullscreen
        case .settings: return .settings
        case .captions: return .captions
        case .next: return .next
        case .previous: return .previous
        case .theater: return .theater
        case .miniplayer: return .miniplayer
        }
    }

    private static func rows(
        from scene: VisionScene, pid: pid_t, appName: String, windowTitle: String
    ) -> [AXScreenElement] {
        scene.roster(pid: pid, appName: appName, windowTitle: windowTitle).map { row in
            AXScreenElement(
                ordinal: row.ordinal,
                id: AXNodeID(raw: row.id.raw),
                pid: pid,
                appName: appName,
                windowID: AXNodeID(raw: row.windowID.raw),
                windowTitle: windowTitle,
                role: row.role,
                subrole: row.subrole,
                category: AXNodeCategory.category(role: row.role, subrole: row.subrole),
                label: row.label,
                frame: row.frame,
                isEnabled: row.isEnabled,
                isFocused: row.isFocused,
                // SEEN, NOT WALKED. There is no element behind this row to press by
                // name — only a place on screen to click.
                provenance: .seen)
        }
    }
}

/// The engine and the model, built once.
///
/// PIN: A CLASS, NOT AN ACTOR. `VisionEngine` holds no per-call state and is documented
/// Sendable for exactly this reason; an actor here would serialize page reads behind
/// one executor for no safety anyone needed.
final class VisionSession: @unchecked Sendable {
    let engine: VisionEngine
    /// Nil when no model is installed. The media lane does not need one.
    let classifier: RegionClassifier?
    /// Where the model was found, for a probe to print.
    let modelLocation: URL?

    private static let box = OSAllocatedUnfairLock<Result<VisionSession, Error>?>(
        initialState: nil)

    static func shared() throws -> VisionSession {
        if let existing = box.withLock({ $0 }) { return try existing.get() }
        let built = Result { try VisionSession() }
        box.withLock { $0 = built }
        return try built.get()
    }

    private init() throws {
        engine = try VisionEngine()
        // A MISSING MODEL IS A CONFIGURATION; A BROKEN ONE IS A FAULT. `bundled` throws
        // only for the second, so this swallows nothing that matters.
        classifier = try? RegionClassifier.bundled()
        modelLocation = RegionClassifier.resourceBundleLocation()
    }
}
