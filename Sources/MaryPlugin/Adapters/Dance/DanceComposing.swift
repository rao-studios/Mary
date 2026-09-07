//
//  DanceComposing.swift
//  MaryPlugin
//
//  WHAT: The composer seam — who writes the shader, and what it is asked.
//  IN:   DanceEngine
//  OUT:  DanceBrief → DanceComposition; implemented in MaryBrain over Seer
//  PIN:  MaryPlugin never calls a model. The brain conforms to this and the
//        runtime injects it, the way LookingPlugin takes its describer.
//

import Foundation

/// Whose feeling the shader is about.
public enum DanceSubject: String, Sendable, Equatable {
    /// A dance: energy, no one's mood in particular.
    case dance
    /// Mary's own feeling, asked of her.
    case mary
    /// What Mary reads in the person.
    case person
}

/// What the composer is told.
public struct DanceBrief: Sendable, Equatable {
    public var subject: DanceSubject
    /// What the person said, verbatim.
    public var utterance: String
    /// A mood the person named, or a hint the caller derived. Optional.
    public var moodHint: String?
    /// Two or three words of entropy — palette, motion, texture — so a
    /// deterministic composer still varies between dances.
    public var motifs: [String]
    /// A previous attempt and what was wrong with it, for one repair round.
    public var repair: Repair?

    public struct Repair: Sendable, Equatable {
        public var glsl: String
        public var problem: String
        public init(glsl: String, problem: String) {
            self.glsl = glsl
            self.problem = problem
        }
    }

    public init(
        subject: DanceSubject, utterance: String, moodHint: String? = nil,
        motifs: [String] = [], repair: Repair? = nil
    ) {
        self.subject = subject
        self.utterance = utterance
        self.moodHint = moodHint
        self.motifs = motifs
        self.repair = repair
    }
}

/// What comes back: one spoken sentence, and the shader.
public struct DanceComposition: Sendable, Equatable {
    /// One sentence Mary can say — "Restless, mostly."
    public var feeling: String
    /// The fragment shader source, as the composer wrote it (fences and all —
    /// `GLSLFragment.admit` takes it from there).
    public var glsl: String

    public init(feeling: String, glsl: String) {
        self.feeling = feeling
        self.glsl = glsl
    }
}

/// Why a composer could not answer, in a sentence.
public enum DanceComposerError: Error, Sendable, Equatable {
    case unavailable(String)
    case failed(String)
    case unparsable(String)

    public var summary: String {
        switch self {
        case .unavailable(let why): return why
        case .failed(let why): return why
        case .unparsable(let why): return why
        }
    }
}

public protocol DanceComposing: Sendable {
    func isReady() async -> Bool
    func compose(_ brief: DanceBrief) async throws -> DanceComposition
}

/// A composer with nothing behind it — what a bench or a probe without a
/// brain installs, so the Skills exist and refuse by name.
public struct UnavailableDanceComposer: DanceComposing {
    public var reason: String
    public init(reason: String = "no composer is installed.") { self.reason = reason }
    public func isReady() async -> Bool { false }
    public func compose(_ brief: DanceBrief) async throws -> DanceComposition {
        throw DanceComposerError.unavailable(reason)
    }
}

/// The motif vocabulary. Small on purpose: a composer asked for "amber, drift,
/// grain" writes a different shader from one asked for "teal, pulse, ripple".
public enum DanceMotifs {
    public static let palettes = [
        "amber", "teal", "magenta", "ultramarine", "coral", "moss", "violet", "gold",
        "ice", "rust", "rose", "cyan",
    ]
    public static let motions = [
        "drift", "pulse", "spiral", "breathe", "ripple", "surge", "orbit", "flicker",
        "sway", "cascade",
    ]
    public static let textures = [
        "grain", "silk", "smoke", "glass", "dunes", "ink", "velvet", "static", "water",
        "honey",
    ]

    /// One from each, chosen by `random` in 0..<1.
    public static func pick(random: (ClosedRange<Double>) -> Double) -> [String] {
        func one(_ words: [String]) -> String {
            let index = Int(random(0...0.999_999) * Double(words.count))
            return words[min(max(index, 0), words.count - 1)]
        }
        return [one(palettes), one(motions), one(textures)]
    }
}
