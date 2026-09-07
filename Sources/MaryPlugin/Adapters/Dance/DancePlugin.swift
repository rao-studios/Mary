//
//  DancePlugin.swift
//  MaryPlugin
//
//  WHAT: Dance as Skills — start a dance, show a mood, stop.
//  IN:   composition root (a composer from the brain), CanvasService
//  OUT:  start_dance / show_mood / stop_dance
//  PIN:  THE CANVAS'S FLAGSHIP, not its owner. Everything on screen goes
//        through CanvasService; this adds only the shader and the beat.
//        Appended, not catalogued — it takes an injected composer.
//

import Foundation
import MaryFoundation

public struct DancePlugin: MaryAdapter {
    public static let adapterID = "dance"

    public let name = Self.adapterID
    public let summary = "Compose a shader on the fly and dance it across the screen, or hold one still as a mood."
    public let abilities: Set<AbilityID> = [.dance]
    /// Empty: an alias names an application, and this names none.
    public let applicationAliases: Set<String> = []

    private let engine: DanceEngine

    public init(compose: any DanceComposing, canvas: CanvasService = .live) {
        self.engine = DanceEngine(seams: .init(canvas: canvas, compose: compose))
    }

    public init(engine: DanceEngine) {
        self.engine = engine
    }

    public var promptFragment: String? {
        """
        The Dance Ability paints shaders in Mary's own windows. start_dance for a \
        light show to a beat; show_mood when asked how Mary feels or what the user \
        seems to feel — one still window, no dance. stop_dance takes it all down. \
        Never for a page with content; that is the Canvas Ability's present_page.
        """
    }

    public var servedAttention: AmbientAttention? { nil }

    public var adapterManifest: InstalledAdapterManifest {
        let adapterID = AdapterID(Self.adapterID)
        // EACH OPERATION CLAIMS THE CANVAS CAPABILITY IT SPENDS, because a
        // Skill is ready only when its own binding claims everything it
        // requires — the canvas's contract is honoured through this adapter.
        func operation(_ name: String, capabilities: [CapabilityID]) -> InstalledAdapterBinding {
            InstalledAdapterBinding(
                adapterID: adapterID,
                operation: name,
                capabilities: capabilities,
                inputTypes: [],
                outputTypes: [],
                targetClasses: [])
        }
        return InstalledAdapterManifest(
            adapterID: adapterID,
            title: "Dance",
            transport: .native,
            claimCoverage: .complete,
            operations: [
                operation("start_dance", capabilities: ["dance.perform", "canvas.present"]),
                operation("show_mood", capabilities: ["dance.mood", "canvas.present"]),
                operation("stop_dance", capabilities: ["dance.stop", "canvas.dismiss"]),
            ],
            supportedValueTypes: [])
    }

    public var skillBindings: [SkillBinding] {
        [startDance, showMood, stopDance]
    }

    private var startDance: SkillBinding {
        SkillBinding(
            name: "start_dance",
            description: "Compose a shader and dance it across the screen — several of Mary's own windows opening and closing to a random beat for fifteen seconds. Use when the user says let's dance, put on a show, or wants a light show.",
            parameters: [
                .init(name: "mood", type: "string",
                      description: "A mood or feel for the shader, in the user's words, when they named one.",
                      required: false),
            ],
            access: .tweak,
            backing: .native { [engine] arguments, context in
                let brief = DanceBrief(
                    subject: .dance, utterance: context.utterance,
                    moodHint: arguments["mood"]?.trimmingCharacters(in: .whitespacesAndNewlines))
                switch await engine.dance(brief) {
                case .refused(let refusal):
                    return SkillOutcome(ok: false, summary: refusal.summary)
                case .started(let feeling):
                    return SkillOutcome(ok: true, summary: "Dancing — \(feeling)", landed: true)
                }
            },
            stage: true)
    }

    private var showMood: SkillBinding {
        SkillBinding(
            name: "show_mood",
            description: "Show a feeling as one still shader in a window of Mary's own — how Mary feels right now, or what she reads in the user. No dance. Use when asked how are you feeling, how do you feel, or what do you think I feel like.",
            parameters: [
                .init(name: "subject", type: "string",
                      description: "yours for Mary's own feeling, mine for the user's. Omit to read it from the question.",
                      required: false, enumValues: ["yours", "mine"]),
                .init(name: "mood", type: "string",
                      description: "A mood the user named, when they did.",
                      required: false),
            ],
            access: .tweak,
            backing: .native { [engine] arguments, context in
                let subject = Self.subject(argument: arguments["subject"], utterance: context.utterance)
                let brief = DanceBrief(
                    subject: subject, utterance: context.utterance,
                    moodHint: arguments["mood"]?.trimmingCharacters(in: .whitespacesAndNewlines))
                switch await engine.mood(brief) {
                case .refused(let refusal):
                    return SkillOutcome(ok: false, summary: refusal.summary)
                case .started(let feeling):
                    return SkillOutcome(
                        ok: true,
                        summary: "\(feeling) Have a look — it steps aside if you ask me to do something else.",
                        landed: true)
                }
            },
            stage: true)
    }

    private var stopDance: SkillBinding {
        SkillBinding(
            name: "stop_dance",
            description: "Stop the dance or take the mood window down.",
            access: .tweak,
            backing: .native { [engine] _, _ in
                guard await engine.stop() else {
                    return SkillOutcome(ok: true, summary: DanceRefusal.nothingToStop.summary)
                }
                return SkillOutcome(ok: true, summary: "Done.", landed: true)
            })
    }

    /// Whose feeling: the argument when given, else the pronouns in the sentence.
    static func subject(argument: String?, utterance: String) -> DanceSubject {
        switch argument?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "mine", "me", "user", "person": return .person
        case "yours", "you", "mary": return .mary
        default: break
        }
        let words = Set(
            utterance.lowercased()
                .split { !$0.isLetter && $0 != "'" }
                .map(String.init))
        let aboutMe = !words.isDisjoint(with: ["i", "i'm", "im", "me", "my", "mine", "myself"])
        let aboutYou = !words.isDisjoint(with: ["you", "you're", "youre", "your", "yours", "yourself", "mary"])
        // "What do you think I feel like" names both; the feeling is the person's.
        if aboutMe { return .person }
        if aboutYou { return .mary }
        return .mary
    }
}
