//
//  MediaControlReading.swift
//  MaryComputerUse
//
//  WHAT: A player's transport in SCREEN points — where to click, and what is playing.
//  IN:   VisionPageReader (converted out of VisionAX's pixel-space detection)
//  OUT:  browsing skills; the web probe
//  PIN:  MARY'S OWN TYPE, ON MARY'S OWN PLANE. VisionAX answers in image pixels and
//        replicates our AX type names; converting here is what keeps its vocabulary
//        from leaking into every caller, and what makes "where do I click" a question
//        with one answer instead of one answer per density.
//        NIL IS A FAILED READ, NEVER AN "OFF". `isMuted == nil` means no volume control
//        was named — not that the sound is on. The whole surface pattern turns on that
//        distinction and this type keeps it.
//

import CoreGraphics
import Foundation

public struct MediaControlReading: Sendable, Equatable {

    public enum Playback: String, Sendable, Equatable {
        case playing
        case paused
        case unknown
    }

    /// What a control depicts. Mirrors VisionAX's vocabulary, converted at the seam.
    public enum Glyph: String, Sendable, Equatable, CaseIterable {
        case none, play, pause, replay, volume, muted, fullscreen, exitFullscreen
        case settings, captions, next, previous, theater, miniplayer
    }

    public struct Control: Sendable, Equatable {
        /// Global, top-left screen points.
        public var frame: CGRect
        public var glyph: Glyph
        public var confidence: Double

        public init(frame: CGRect, glyph: Glyph, confidence: Double) {
            self.frame = frame
            self.glyph = glyph
            self.confidence = confidence
        }

        /// Where a click goes.
        public var clickPoint: CGPoint {
            CGPoint(x: frame.midX.rounded(), y: frame.midY.rounded())
        }
    }

    public struct Progress: Sendable, Equatable {
        public var frame: CGRect
        public var fraction: Double

        public init(frame: CGRect, fraction: Double) {
            self.frame = frame
            self.fraction = fraction
        }
    }

    /// The page or player region this reading was taken over.
    public var pageFrame: CGRect
    public var controlsVisible: Bool
    public var playback: Playback
    /// What decided `playback`, in the words the engine used.
    public var witnesses: [String]
    public var playPause: Control?
    public var volume: Control?
    public var fullscreen: Control?
    public var centerGlyph: Control?
    public var others: [Control]
    public var progress: Progress?
    /// The short track beside the volume control. Present only while the pointer is
    /// over that control, so nil usually means "not revealed" rather than "not there".
    public var volumeTrack: Progress?
    public var elapsed: TimeInterval?
    public var duration: TimeInterval?
    public var capturedAt: Date

    public init(
        pageFrame: CGRect,
        controlsVisible: Bool = false,
        playback: Playback = .unknown,
        witnesses: [String] = [],
        playPause: Control? = nil,
        volume: Control? = nil,
        fullscreen: Control? = nil,
        centerGlyph: Control? = nil,
        others: [Control] = [],
        progress: Progress? = nil,
        volumeTrack: Progress? = nil,
        elapsed: TimeInterval? = nil,
        duration: TimeInterval? = nil,
        capturedAt: Date = Date()
    ) {
        self.pageFrame = pageFrame
        self.controlsVisible = controlsVisible
        self.playback = playback
        self.witnesses = witnesses
        self.playPause = playPause
        self.volume = volume
        self.fullscreen = fullscreen
        self.centerGlyph = centerGlyph
        self.others = others
        self.progress = progress
        self.volumeTrack = volumeTrack
        self.elapsed = elapsed
        self.duration = duration
        self.capturedAt = capturedAt
    }

    /// Whether the volume control says the sound is off. Nil when none was named.
    public var isMuted: Bool? {
        switch volume?.glyph {
        case .muted: return true
        case .volume: return false
        default: return nil
        }
    }

    /// Where to click on the progress track to land at `fraction`.
    ///
    /// Reuses the page lane's own track geometry, insets and all: a click on the very
    /// end of a track lands outside it as often as not, and that rule is already
    /// written down once.
    public func seekPoint(fraction: Double) -> CGPoint? {
        guard let progress else { return nil }
        return PageElementActions.screenPoint(
            forFraction: fraction, in: progress.frame, orientation: .horizontal)
    }

    /// Where to click on the volume track to land at `fraction`.
    ///
    /// PIN: THE TRACK IS ONLY THERE WHILE THE POINTER IS. A player draws its volume
    /// slider on hover and takes it away again, so a caller reads, hovers the volume
    /// control, reads AGAIN, and only then has a track to aim at.
    public func volumePoint(fraction: Double) -> CGPoint? {
        guard let volumeTrack else { return nil }
        return PageElementActions.screenPoint(
            forFraction: fraction, in: volumeTrack.frame, orientation: .horizontal)
    }

    /// The sentence a skill and the probe both say, so the two never drift.
    public var spoken: String {
        var sentence: String
        switch playback {
        case .playing: sentence = "Playing"
        case .paused: sentence = "Paused"
        case .unknown:
            sentence = controlsVisible
                ? "I can see the player, but I can't tell whether it's playing"
                : "I can't see the player's controls"
        }
        if playback != .unknown, let elapsed {
            if let duration, duration > 0 {
                sentence += ", \(Self.clock(elapsed)) of \(Self.clock(duration))"
            } else {
                sentence += " at \(Self.clock(elapsed))"
            }
        } else if playback != .unknown, let progress {
            sentence += String(format: ", %.0f%% through", progress.fraction * 100)
        }
        if isMuted == true { sentence += ", muted" }
        return sentence + "."
    }

    /// `4:56`, or `1:02:03` past the hour.
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainder = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }
}
