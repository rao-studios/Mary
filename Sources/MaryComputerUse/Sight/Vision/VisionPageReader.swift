//
//  VisionPageReader.swift
//  MaryComputerUse
//
//  WHAT: What is on a page, read from its pixels. THE ONLY FILE THAT IMPORTS THE VISION
//        ENGINE — as `FrigateVision`, which re-exports VisionAX.
//  IN:   WindowPixels + FrigateVision
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
import FrigateVision
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
        /// Whether a role classifier ran. False means the roles are shape and position
        /// rather than a model's word — NOT that the reading is empty.
        public var classified: Bool
        /// What the map said about each row, keyed by ordinal.
        public var map: PageMapSummary

        public init(
            elements: [AXScreenElement] = [],
            media: MediaControlReading? = nil,
            pageFrame: CGRect,
            pixelsPerPoint: Double,
            duration: Duration = .zero,
            classified: Bool = false,
            map: PageMapSummary = PageMapSummary()
        ) {
            self.elements = elements
            self.media = media
            self.pageFrame = pageFrame
            self.pixelsPerPoint = pixelsPerPoint
            self.duration = duration
            self.classified = classified
            self.map = map
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
        // NO CLASSIFIER IS NOT NO ANSWER, AND THIS USED TO REFUSE. The map is built
        // from edges, recognized words and geometry; a model names roles, it does not
        // supply the rows. A machine without one still reads a page of results — it
        // just calls a text field "field 2" instead of naming it — so the reading says
        // `classified: false` and carries on rather than throwing away the page.

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
        var elements: [AXScreenElement] = []
        var summary = PageMapSummary()
        if intent == .elements {
            (elements, summary) = rows(
                from: scene, pid: pid, appName: appName, windowTitle: windowTitle)
        }

        ComputerUseMonitor.shared.note(
            lane: .sight, act: "perceive", pid: pid,
            detail: "\(intent.rawValue) \(elements.count) elements"
                + (intent == .elements
                    ? " · \(Int((summary.labeledFraction * 100).rounded()))% named"
                        + " · \(summary.groups.count) groups"
                    : "")
                + (media.map { " · \($0.others.count) controls · \($0.playback.rawValue)" } ?? "")
                + " · \(elapsed)")
        return Reading(
            elements: elements,
            media: media,
            pageFrame: pageFrame,
            pixelsPerPoint: frame.pixelsPerPoint,
            duration: elapsed,
            classified: classifier != nil,
            map: summary)
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
            volumeTrack: detection.volumeTrack.map {
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

    /// The map's elements as Mary's rows, in reading order, in screen points.
    ///
    /// PIN: THE MAP, NOT THE ROSTER. `VisionScene.roster` drops any node the classifier
    /// did not name and any node with no words inside it — which on a page of search
    /// results is nearly all of them. Measured: a results page read as four chrome
    /// buttons. The map keeps those rows and says how sure their names are instead, and
    /// this crossing carries that judgement over as `PageMapSummary` rather than
    /// throwing it away at the door.
    static func rows(
        from scene: VisionScene, pid: pid_t, appName: String, windowTitle: String,
        limit: Int = 160
    ) -> ([AXScreenElement], PageMapSummary) {
        let map = scene.pageMap()
        var rows: [AXScreenElement] = []
        var annotations: [Int: SeenElementAnnotation] = [:]
        var ordinalByID: [UInt: Int] = [:]

        for element in map.elements.prefix(limit) {
            let ordinal = rows.count + 1
            let role = element.role
                ?? (element.affordance == .press ? "AXLink" : "AXStaticText")
            let group = map.group(element.groupID)
            rows.append(AXScreenElement(
                ordinal: ordinal,
                id: AXNodeID(raw: element.id.raw),
                pid: pid,
                appName: appName,
                windowID: AXNodeID(raw: 1),
                windowTitle: windowTitle,
                role: role,
                subrole: element.subrole,
                category: AXNodeCategory.category(role: role, subrole: element.subrole),
                label: element.label,
                frame: scene.projection.screenRect(element.frame),
                isEnabled: element.isEnabled,
                isFocused: false,
                // THE GROUP IS THE ROW'S CONTEXT, and it is what lets a listing say
                // which of four "Watch" buttons is meant.
                containerTrail: [group?.title, group.map { $0.kind.rawValue }]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty },
                // SEEN, NOT WALKED. There is no element behind this row to press by
                // name — only a place on screen to click.
                provenance: .seen))
            annotations[ordinal] = SeenElementAnnotation(
                affordance: affordance(element.affordance),
                affordanceSource: affordanceSource(element.affordanceSource),
                labelSource: labelSource(element.labelSource),
                hints: element.hints,
                groupID: element.groupID,
                confidence: element.confidence)
            ordinalByID[element.id.raw] = ordinal
        }

        let groups = map.groups.map { group in
            SeenGroup(
                id: group.id,
                kind: group.kind.rawValue,
                title: group.title,
                memberOrdinals: group.memberIDs.compactMap { ordinalByID[$0.raw] }.sorted())
        }
        return (rows, PageMapSummary(
            groups: groups, annotations: annotations,
            labeledFraction: map.labeledFraction))
    }

    /// Vocabulary conversions, spelled out for the same reason the glyph one is: both
    /// sides are string-backed, so a rawValue hop would compile and answer wrongly the
    /// day either is extended.
    private static func affordance(_ value: PageAffordance) -> SeenAffordance {
        switch value {
        case .press: return .press
        case .fill: return .fill
        case .adjust: return .adjust
        case .scroll: return .scroll
        case .none: return .none
        }
    }

    private static func affordanceSource(
        _ value: PageAffordanceSource
    ) -> SeenAffordanceSource {
        switch value {
        case .classifier: return .classifier
        case .grouping: return .grouping
        case .shape: return .shape
        case .unknown: return .unknown
        }
    }

    private static func labelSource(_ value: PageLabelSource) -> SeenLabelSource {
        switch value {
        case .classifier: return .classifier
        case .textInside: return .textInside
        case .textAdjacent: return .textAdjacent
        case .icon: return .icon
        case .synthesized: return .synthesized
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
