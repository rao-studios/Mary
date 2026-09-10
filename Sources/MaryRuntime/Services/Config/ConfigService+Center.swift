//
//  ConfigService+Center.swift
//  MaryRuntime
//
//  WHAT: Persisted Settings — engines, voices, projects, servers, plugins.
//  OUT:  ConfigService.Update; MaryRuntime appliers on swap
//  PIN:  On-device voice and hosted character are separate fields.
//

import MaryAmbient
import MaryBrain
import MaryPlugin
import MaryVoice
import Granite
import SwiftUI

/// A "common project" voice commands can open: name → path on disk.
package struct ProjectRef: GraniteModel, Identifiable {
    package var id: UUID = .init()
    package var name: String = ""
    package var path: String = ""

    package init(id: UUID = .init(), name: String = "", path: String = "") {
        self.id = id
        self.name = name
        self.path = path
    }
}

/// A user-supplied pronunciation override: word → Kokoro-notation IPA.
package struct PronunciationRef: GraniteModel, Identifiable {
    package var id: UUID = .init()
    package var word: String = ""
    package var ipa: String = ""

    package init(id: UUID = .init(), word: String = "", ipa: String = "") {
        self.id = id
        self.word = word
        self.ipa = ipa
    }
}

extension ConfigService {
    package struct Center: GraniteCenter {
        package init() {}
        package struct State: GraniteState {
            /// Which backend Sewn uses for spoken replies (Lane A). Mistral by
            /// default — every lane rides Sewn now, and the hosted vendor is
            /// what a fresh install can answer with immediately.
            package var llmEngine: LLMEngineChoice = .mistral
            /// Lane B: which backend synthesizes skill invocations. The skills
            /// themselves still run on this Mac either way.
            package var skillEngine: LLMEngineChoice = .mistral
            /// Corpus crawl when a unit settles. On by default. Headers + summaries only.
            package var ambientCorpusIndexing: Bool = true
            package var sttBackend: STTBackend = .apple
            package var ttsBackend: TTSBackend = .sewn
            /// On-device Kokoro voice (bundle voices/). Never a hosted character — see sewnVoice.
            package var voice: String = "af_heart"
            /// Hosted VoiceCharacter slug (`fr_marie`). Separate from `voice` — different namespaces.
            package var sewnVoice: String = VoiceCharacter.marie.id
            package var speechStyle: SpeechStyleSelection = .auto
            package var vad: VADConfig = .init()
            package var projects: [ProjectRef] = []
            package var customPronunciations: [PronunciationRef] = []
            /// Plugins the user switched OFF. Empty = all shipped plugins installed.
            package var disabledPlugins: [String] = []
            /// DERIVED from `disabledPlugins`, never written directly: the ids
            /// the brain installs. Kept as the same optional roster every
            /// consumer already reads, so the inversion stops at this file.
            package var enabledPlugins: [String]? = nil
            /// Persisted one-time migration marker. Keep this in the state,
            /// not Granite's envelope: the envelope version is not surfaced
            /// during restore.
            package static let currentCodingAgentMigrationVersion = 20260817
            /// Rolling context window: spoken messages the brain keeps.
            package var historyMessageLimit: Int = 12
            /// "Hey Mary" standby. On by default. Mic indicator stays lit while armed.
            package var wakeWordEnabled: Bool = true

            // Sewn/Thread local stack. Chat runs in sewn mode whenever
            // sewnEnabled and the stack + sign-in are up; otherwise the
            // engine-only legacy path carries the turn.
            package var sewnEnabled: Bool = true
            package var autoStartServers: Bool = true
            package var sewnCheckoutPath: String = ServerSpec.Defaults.sewnCheckoutPath
            package var threadCheckoutPath: String = ServerSpec.Defaults.threadCheckoutPath
            /// Where each server keeps its state (`--data-dir`). Defaults live
            /// under ~/Documents/maryOS; one directory per server.
            package var sewnDataDir: String = ServerSpec.Defaults.sewnDataDir
            package var threadDataDir: String = ServerSpec.Defaults.threadDataDir
            package var fleetDataDir: String = ServerSpec.Defaults.fleetDataDir
            package var sewnPort: Int = ServerSpec.Defaults.sewnPort
            package var sewnGRPCPort: Int = ServerSpec.Defaults.sewnGRPCPort
            package var threadPort: Int = ServerSpec.Defaults.threadPort
            package var threadGRPCPort: Int = ServerSpec.Defaults.threadGRPCPort
            /// The thread node UUID = the DB identity. Empty until first boot
            /// adopts Thread's persisted id (or mints one); after that it's
            /// pinned so the same DB loads every launch.
            package var threadNodeID: String = ""
            package var sewnEmail: String = ServerSpec.Defaults.sewnEmail
            package var sewnPassword: String = ServerSpec.Defaults.sewnPassword
            /// Graph-extraction backend Thread launches with. "mistral" by
            /// default: the mlx default silently degrades to keyword-only
            /// when the build lacks a metallib.
            package var threadGraphBackend: String = ServerSpec.Defaults.threadGraphBackend
            package var fleetCheckoutPath: String = ServerSpec.Defaults.fleetCheckoutPath
            package var fleetPort: Int = ServerSpec.Defaults.fleetPort
            package var fleetGRPCPort: Int = ServerSpec.Defaults.fleetGRPCPort
            /// Whether Mary pushes its graph policy (custom ontology kinds,
            /// co-mention edges) to Thread after boot.
            package var threadGraphPolicyManaged: Bool = true
            /// Chat model sent to Sewn; empty = Sewn's default (Mistral).
            /// The user's lever on thinking-model first-token latency.
            package var sewnChatModel: String = ""
            /// Which route carries Sewn-mode turns: classic SSE + /v1/speak,
            /// or the realtime WebSocket with server-side interleaved audio.
            package var sewnTransport: SewnTransportChoice = .classic
            /// On-device coding agent. Off until Settings downloads a model
            /// and selects it — Hub fetch, never vendored weights.
            package var codingAgentEnabled: Bool = false
            /// Which backend synthesizes pair-coding rounds. Always through
            /// Sewn's `/v1/code/complete`; file tools stay on this Mac.
            package var codingEngine: LLMEngineChoice = .mistral
            /// How long an ordinary Skill may stay running (1…20 s). Named
            /// build/test bindings keep their own ceilings.
            package var skillRunTimeoutSeconds: Double = 2
            /// What one model call is worth, for Ability Studio's per-run
            /// estimate. Zero by default: Mary makes no claim about pricing.
            package var modelCallPriceUSD: Double = 0

            /// How much of itself the idle Life engine is allowed to be.
            /// `.off` on a fresh install: acting unattended is a thing the
            /// user turns on after watching it in Observe.
            package var lifeMode: LifeMode = .off
            /// Disciplines whose ready adapter may answer a live turn in
            /// place of tool-calling. Opt-in, per ability, always empty here.
            package var lifeTurnDisciplines: [String] = []

            enum CodingKeys: String, CodingKey {
                case ambientCorpusIndexing
                case llmEngine, skillEngine, sttBackend, ttsBackend, voice, sewnVoice, speechStyle, vad,
                     projects, customPronunciations, enabledPlugins, disabledPlugins,
                     historyMessageLimit, wakeWordEnabled
                case sewnEnabled, autoStartServers, sewnCheckoutPath, threadCheckoutPath, sewnPort, sewnGRPCPort, threadPort, threadGRPCPort, threadNodeID, sewnEmail, sewnPassword, threadGraphBackend, fleetCheckoutPath, fleetPort, fleetGRPCPort, threadGraphPolicyManaged, sewnChatModel, sewnTransport
                case sewnDataDir, threadDataDir, fleetDataDir
                case codingAgentEnabled, codingEngine
                case skillRunTimeoutSeconds
                case modelCallPriceUSD
                case lifeMode, lifeTurnDisciplines
            }

            package init() {}

            /// Tolerant decode: a missing key must NEVER fail the restore —
            /// a thrown decode makes Granite re-seed defaults (Gita's rule).
            package init(from decoder: Decoder) throws {
                self.init()
                let c = try decoder.container(keyedBy: CodingKeys.self)
                llmEngine = try c.decodeIfPresent(LLMEngineChoice.self, forKey: .llmEngine) ?? .mistral
                lifeMode = try c.decodeIfPresent(LifeMode.self, forKey: .lifeMode) ?? .off
                lifeTurnDisciplines = try c.decodeIfPresent(
                    [String].self, forKey: .lifeTurnDisciplines) ?? []
                skillEngine = try c.decodeIfPresent(LLMEngineChoice.self, forKey: .skillEngine) ?? .mistral
                ambientCorpusIndexing = try c.decodeIfPresent(
                    Bool.self, forKey: .ambientCorpusIndexing) ?? true
                sttBackend = try c.decodeIfPresent(STTBackend.self, forKey: .sttBackend) ?? .apple
                ttsBackend = try c.decodeIfPresent(TTSBackend.self, forKey: .ttsBackend) ?? .sewn
                voice = try c.decodeIfPresent(String.self, forKey: .voice) ?? "af_heart"
                sewnVoice = try c.decodeIfPresent(String.self, forKey: .sewnVoice)
                    ?? VoiceCharacter.marie.id
                // Migrate hosted character out of the on-device voice slot.
                if let hosted = VoiceCharacter.all.first(where: { $0.id == voice }) {
                    if !c.contains(.sewnVoice) { sewnVoice = hosted.id }
                    voice = Self().voice
                }

                speechStyle = try c.decodeIfPresent(SpeechStyleSelection.self, forKey: .speechStyle) ?? .auto
                vad = try c.decodeIfPresent(VADConfig.self, forKey: .vad) ?? .init()
                projects = try c.decodeIfPresent([ProjectRef].self, forKey: .projects) ?? []
                customPronunciations = try c.decodeIfPresent([PronunciationRef].self, forKey: .customPronunciations) ?? []
                // Deviation list — a plugin added since last write is installed, not hidden.
                disabledPlugins = try c.decodeIfPresent(
                    [String].self, forKey: .disabledPlugins) ?? []
                enabledPlugins = MaryAdapterCatalog.adapters()
                    .map(\.name)
                    .filter { !disabledPlugins.contains($0) }
                historyMessageLimit = try c.decodeIfPresent(
                    Int.self, forKey: .historyMessageLimit) ?? 12

                // Decode through String, not the enum — unknown value must not throw (re-seeds all).

                wakeWordEnabled = try c.decodeIfPresent(Bool.self, forKey: .wakeWordEnabled) ?? true
                sewnEnabled = try c.decodeIfPresent(Bool.self, forKey: .sewnEnabled) ?? true
                autoStartServers = try c.decodeIfPresent(Bool.self, forKey: .autoStartServers) ?? true
                sewnCheckoutPath = try c.decodeIfPresent(String.self, forKey: .sewnCheckoutPath) ?? ServerSpec.Defaults.sewnCheckoutPath
                threadCheckoutPath = try c.decodeIfPresent(String.self, forKey: .threadCheckoutPath) ?? ServerSpec.Defaults.threadCheckoutPath
                sewnDataDir = try c.decodeIfPresent(String.self, forKey: .sewnDataDir) ?? ServerSpec.Defaults.sewnDataDir
                threadDataDir = try c.decodeIfPresent(String.self, forKey: .threadDataDir) ?? ServerSpec.Defaults.threadDataDir
                fleetDataDir = try c.decodeIfPresent(String.self, forKey: .fleetDataDir) ?? ServerSpec.Defaults.fleetDataDir
                sewnPort = try c.decodeIfPresent(Int.self, forKey: .sewnPort) ?? ServerSpec.Defaults.sewnPort
                sewnGRPCPort = try c.decodeIfPresent(Int.self, forKey: .sewnGRPCPort) ?? ServerSpec.Defaults.sewnGRPCPort
                threadPort = try c.decodeIfPresent(Int.self, forKey: .threadPort) ?? ServerSpec.Defaults.threadPort
                threadGRPCPort = try c.decodeIfPresent(Int.self, forKey: .threadGRPCPort) ?? ServerSpec.Defaults.threadGRPCPort
                threadNodeID = try c.decodeIfPresent(String.self, forKey: .threadNodeID) ?? ""
                sewnEmail = try c.decodeIfPresent(String.self, forKey: .sewnEmail) ?? ServerSpec.Defaults.sewnEmail
                sewnPassword = try c.decodeIfPresent(String.self, forKey: .sewnPassword) ?? ServerSpec.Defaults.sewnPassword
                threadGraphBackend = try c.decodeIfPresent(String.self, forKey: .threadGraphBackend) ?? ServerSpec.Defaults.threadGraphBackend
                fleetCheckoutPath = try c.decodeIfPresent(String.self, forKey: .fleetCheckoutPath) ?? ServerSpec.Defaults.fleetCheckoutPath
                fleetPort = try c.decodeIfPresent(Int.self, forKey: .fleetPort) ?? ServerSpec.Defaults.fleetPort
                fleetGRPCPort = try c.decodeIfPresent(Int.self, forKey: .fleetGRPCPort) ?? ServerSpec.Defaults.fleetGRPCPort
                threadGraphPolicyManaged = try c.decodeIfPresent(Bool.self, forKey: .threadGraphPolicyManaged) ?? true
                sewnChatModel = try c.decodeIfPresent(String.self, forKey: .sewnChatModel) ?? ""
                sewnTransport = try c.decodeIfPresent(SewnTransportChoice.self, forKey: .sewnTransport) ?? .classic
                codingAgentEnabled = try c.decodeIfPresent(Bool.self, forKey: .codingAgentEnabled) ?? false
                codingEngine = try c.decodeIfPresent(LLMEngineChoice.self, forKey: .codingEngine) ?? .mistral
                skillRunTimeoutSeconds = AbilityRuntime.clampedOrdinarySkillTimeout(
                    try c.decodeIfPresent(Double.self, forKey: .skillRunTimeoutSeconds) ?? 2)
                modelCallPriceUSD = max(
                    0, try c.decodeIfPresent(Double.self, forKey: .modelCallPriceUSD) ?? 0)
            }

            /// name → path for prompt building and activity dispatch.
            package var projectsByName: [String: String] {
                Dictionary(projects.map { ($0.name, $0.path) }, uniquingKeysWith: { a, _ in a })
            }

            /// word → IPA for the engine's custom lexicon.
            package var pronunciationsByWord: [String: String] {
                Dictionary(
                    customPronunciations
                        .filter { !$0.word.isEmpty && !$0.ipa.isEmpty }
                        .map { ($0.word, $0.ipa) },
                    uniquingKeysWith: { a, _ in a })
            }
        }

        @Event package var update: Update.Reducer

        @Store(
            persist: "mary.persistence.config.0001",
            autoSave: true,
            preload: true
        ) public var state: State
    }
}
