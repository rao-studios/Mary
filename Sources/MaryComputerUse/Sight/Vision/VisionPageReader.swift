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

    /// What one page read cost, by stage. `perceive` is what `Reading.duration`
    /// always was; the rest is what it never counted — and on a busy page the
    /// rest is most of it.
    public struct Timing: Sendable, Equatable {
        /// Waking the page's accessibility tree (a Chromium host, once per process).
        public var readiness: Duration = .zero
        /// The accessibility walk of the page.
        public var walk: Duration = .zero
        /// Screen capture — the ScreenCaptureKit round trips.
        public var capture: Duration = .zero
        /// OCR, regions and the classifier.
        public var perceive: Duration = .zero
        /// Publishing the rows as a slate — the embeddings.
        public var publish: Duration = .zero
        public init() {}
        public var total: Duration { readiness + walk + capture + perceive + publish }
    }

    public struct Reading: Sendable {
        /// THE PAGE, IN READING ORDER — the one shape everything above the seal
        /// should read. Screen points, facts already derived.
        public var rows: [PageRow]
        /// The groups those rows sit in.
        public var groups: [PageGroup]
        /// Rows in reading order, screen points, `provenance == .seen`.
        ///
        /// PIN: A SHIM WHILE THE BROWSING LANE MOVES TO `rows`. An AX-shaped
        /// element with an invented role, kept so the old layer compiles; it is
        /// derived from `rows` rather than read separately, so the two cannot
        /// describe different pages.
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
        /// Where the read's time went. Nil for a fake or a fixture.
        public var timing: Timing?

        public init(
            rows: [PageRow] = [],
            groups: [PageGroup] = [],
            elements: [AXScreenElement] = [],
            media: MediaControlReading? = nil,
            pageFrame: CGRect,
            pixelsPerPoint: Double,
            duration: Duration = .zero,
            classified: Bool = false,
            map: PageMapSummary = PageMapSummary(),
            timing: Timing? = nil
        ) {
            self.rows = rows
            self.groups = groups
            self.elements = elements
            self.media = media
            self.pageFrame = pageFrame
            self.pixelsPerPoint = pixelsPerPoint
            self.duration = duration
            self.classified = classified
            self.map = map
            self.timing = timing
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
        let captureStart = ContinuousClock.now
        let frame = try await capture(pid: pid, windowID: windowID, pageFrame: pageFrame)
        let captureElapsed = captureStart.duration(to: .now)
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
        var rows: [PageRow] = []
        var groups: [PageGroup] = []
        var labeledFraction = 0.0
        if intent == .elements {
            (rows, groups, labeledFraction) = Self.rows(
                from: scene, pid: pid, appName: appName, windowTitle: windowTitle)
            // WHERE EACH ROW SITS, DECIDED ONCE, at the seal and beside the
            // facts — for the reason `RowFacts` gives: it is true of the row
            // whether or not anybody is routing, and asking it at ranking time
            // meant asking it again for every goal.
            rows = PageRegionDerivation.assign(rows: rows, pageFrame: pageFrame)
            // AND WHAT IS DRAWN OVER THE PICTURE — a skip control, a prompt —
            // which is an overlay by geometry. See `PagePlayerDerivation`.
            rows = PagePlayerDerivation.markOverlays(rows: rows, pageFrame: pageFrame)
        }
        // THE SHIMS, DERIVED FROM THE ROWS RATHER THAN READ SEPARATELY, so the
        // old AX-shaped view and the new one cannot describe different pages.
        let elements = Self.legacyElements(
            rows, pid: pid, appName: appName, windowTitle: windowTitle)
        let summary = Self.legacyMap(
            rows, groups: groups, labeledFraction: labeledFraction)

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
            rows: rows,
            groups: groups,
            elements: elements,
            media: media,
            pageFrame: pageFrame,
            pixelsPerPoint: frame.pixelsPerPoint,
            duration: elapsed,
            classified: classifier != nil,
            map: summary,
            timing: {
                var timing = Timing()
                timing.capture = captureElapsed
                timing.perceive = elapsed
                return timing
            }())
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
    ) -> (rows: [PageRow], groups: [PageGroup], labeledFraction: Double) {
        let map = scene.pageMap()
        var rows: [PageRow] = []
        var ordinalByID: [UInt: Int] = [:]

        for element in map.elements.prefix(limit) {
            let ordinal = rows.count + 1
            let group = map.group(element.groupID).map {
                PageGroupRef(id: $0.id, kind: groupKind($0.kind), title: $0.title)
            }
            let role = element.role
            rows.append(PageRow(
                ordinal: ordinal,
                frame: scene.projection.screenRect(element.frame),
                label: element.label,
                labelSource: labelSource(element.labelSource),
                affordance: affordance(element.affordance),
                affordanceSource: affordanceSource(element.affordanceSource),
                // THE KIND, FROM WHAT THE MAP ACTUALLY KNOWS. Never from a role
                // this seal invented for it — see `PageRow.role`.
                kind: PageElementKindDerivation.kind(
                    role: role,
                    affordance: affordance(element.affordance),
                    label: element.label,
                    hints: element.hints),
                role: role,
                group: group,
                hints: element.hints,
                confidence: element.confidence,
                isEnabled: element.isEnabled,
                // SEEN, NOT WALKED. There is no element behind this row to press
                // by name — only a place on screen to click.
                provenance: .seen))
            ordinalByID[element.id.raw] = ordinal
        }

        // ONE CONTROL, NOT TWO. See `collapsingNestedDuplicates`.
        let collapsed = collapsingNestedDuplicates(rows, ordinalByID: &ordinalByID)
        rows = collapsed

        let groups = map.groups.map { group in
            PageGroup(
                id: group.id,
                kind: groupKind(group.kind),
                title: group.title,
                memberOrdinals: group.memberIDs.compactMap { ordinalByID[$0.raw] }.sorted())
        }
        // ONE PASS, AT THE SEAL. Every consumer sees the same answers to the same
        // questions — see `RowFacts`.
        return (
            RowFactsDerivation.derive(rows: rows, groups: groups),
            groups,
            map.labeledFraction)
    }

    /// A ROW NESTED INSIDE A ROW WITH THE SAME WORDS IS THE SAME CONTROL.
    ///
    /// PIN: MEASURED ON A LIVE RESULTS PAGE. The reading emitted the site's own
    /// "Images" tab twice — an outer box at 82×26 and an inner one at 68×17,
    /// wholly inside it, carrying the identical label — so naming it asked a
    /// question ("answers to that as well as one other") about one control the
    /// person can see once. Both rows were then marked `duplicateLabel`, which
    /// made the page look as though it held two of everything.
    /// GEOMETRY AND WORDS, NEVER A SITE. Two rows collapse only when one frame
    /// CONTAINS the other and their folded labels are identical — a heading
    /// beside its link keeps both, because neither contains the other, and two
    /// results that happen to share a title keep both, because neither nests.
    /// THE OUTER ONE SURVIVES: it is the whole control, and its frame is what a
    /// press should aim at.
    static func collapsingNestedDuplicates(
        _ rows: [PageRow], ordinalByID: inout [UInt: Int]
    ) -> [PageRow] {
        var dropped = Set<Int>()
        for outer in rows {
            let label = RowFactsDerivation.folded(outer.label)
            guard !label.isEmpty else { continue }
            for inner in rows where inner.ordinal != outer.ordinal
                && !dropped.contains(inner.ordinal)
                && !dropped.contains(outer.ordinal) {
                guard RowFactsDerivation.folded(inner.label) == label,
                      outer.frame.contains(inner.frame),
                      outer.frame != inner.frame
                else { continue }
                dropped.insert(inner.ordinal)
            }
        }
        guard !dropped.isEmpty else { return rows }

        // RENUMBERED IN READING ORDER, because an ordinal is a position a listing
        // speaks and a resolver counts — a gap in it would number the page wrongly.
        var renumbered: [PageRow] = []
        var newOrdinalByOld: [Int: Int] = [:]
        for row in rows where !dropped.contains(row.ordinal) {
            var row = row
            let old = row.ordinal
            row.ordinal = renumbered.count + 1
            newOrdinalByOld[old] = row.ordinal
            renumbered.append(row)
        }
        // A GROUP'S MEMBERS ARE NAMED BY THE OLD ORDINALS, so the identity table
        // the groups are built from moves with them.
        ordinalByID = ordinalByID.compactMapValues { newOrdinalByOld[$0] }
        return renumbered
    }

    // MARK: - Re-sealing a merged reading

    /// A reading whose rows a second lane changed, sealed again.
    ///
    /// PIN: THE SHIMS ARE DERIVED, SO THEY MUST BE RE-DERIVED. `elements` and
    /// `map` are projections of `rows`, joined by ordinal — a merge that renames
    /// a row and renumbers the page would otherwise leave the old layer reading
    /// the old names against the new numbers, which is worse than either lane
    /// alone. One function, so the day a third field is derived from rows there
    /// is one place that forgets it.
    /// `labeledFraction` IS THE PIXEL LANE'S OWN NUMBER and is carried through
    /// unchanged: it answers "how much of what I SAW could I name", and a walked
    /// row is not something the pixel lane saw.
    public static func sealing(
        _ reading: Reading,
        merged: (rows: [PageRow], groups: [PageGroup]),
        pid: pid_t,
        appName: String,
        windowTitle: String
    ) -> Reading {
        var sealed = reading
        let placed = PageRegionDerivation.assign(
            rows: merged.rows, pageFrame: reading.pageFrame)
        // AND THE LISTS THE READING DID NOT FIND. After the regions, because a
        // list is only a list in the page's own column — see `PageListDerivation`.
        let listed = PageListDerivation.lists(rows: placed, groups: merged.groups)
        sealed.rows = RowFactsDerivation.derive(
            rows: listed.rows, groups: listed.groups)
        sealed.groups = listed.groups
        sealed.elements = legacyElements(
            sealed.rows, pid: pid, appName: appName, windowTitle: windowTitle)
        sealed.map = legacyMap(
            sealed.rows, groups: listed.groups,
            labeledFraction: reading.map.labeledFraction)
        return sealed
    }

    // MARK: - The shims

    /// `PageRow` as the AX-shaped element the old browsing layer still reads.
    ///
    /// PIN: TEMPORARY, AND DERIVED — NOT A SECOND READING. The role is invented
    /// here exactly as it used to be invented at the seal, but now it is invented
    /// LAST, out of a row that already knows its own kind, rather than first and
    /// then mined for one. Deleted with the old layer.
    static func legacyElements(
        _ rows: [PageRow], pid: pid_t, appName: String, windowTitle: String
    ) -> [AXScreenElement] {
        rows.map { row in
            let role = row.role
                ?? (row.affordance == .press ? "AXLink" : "AXStaticText")
            return AXScreenElement(
                ordinal: row.ordinal,
                id: AXNodeID(raw: UInt(row.ordinal)),
                pid: pid,
                appName: appName,
                windowID: AXNodeID(raw: 1),
                windowTitle: windowTitle,
                role: role,
                subrole: nil,
                category: AXNodeCategory.category(role: role, subrole: nil),
                label: row.label,
                frame: row.frame,
                isEnabled: row.isEnabled,
                isFocused: false,
                containerTrail: [row.group?.title, row.group?.kind.rawValue]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty },
                provenance: row.provenance)
        }
    }

    /// The side-car the old layer joins by ordinal. Same origin, same answers.
    static func legacyMap(
        _ rows: [PageRow], groups: [PageGroup], labeledFraction: Double
    ) -> PageMapSummary {
        var annotations: [Int: SeenElementAnnotation] = [:]
        for row in rows {
            annotations[row.ordinal] = SeenElementAnnotation(
                affordance: row.affordance,
                affordanceSource: row.affordanceSource,
                labelSource: row.labelSource,
                hints: row.hints,
                groupID: row.group?.id,
                confidence: row.confidence)
        }
        return PageMapSummary(
            groups: groups.map {
                SeenGroup(
                    id: $0.id, kind: $0.kind.rawValue, title: $0.title,
                    memberOrdinals: $0.memberOrdinals)
            },
            annotations: annotations,
            labeledFraction: labeledFraction)
    }

    /// Vocabulary conversion, spelled out for the reason the others are.
    private static func groupKind(_ value: PageGroupKind) -> SeenGroupKind {
        switch value {
        case .row: return .row
        case .card: return .card
        case .list: return .list
        case .form: return .form
        case .toolbar: return .toolbar
        case .overlay: return .overlay
        case .band: return .band
        }
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
