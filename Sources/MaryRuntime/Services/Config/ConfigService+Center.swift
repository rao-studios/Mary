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
            /// Hosted by default — matches seerEnabled / autoStartServers and the turn loop.
            package var llmEngine: LLMEngineChoice = .hosted
            /// Lane B: where skill invocations are synthesized. Local by
            /// default — acting stayed on-device even when spoken turns
            /// already went through Seer, and that remains the install.
            package var skillEngine: LLMEngineChoice = .local
            /// Corpus crawl when a unit settles. On by default. Headers + summaries only.
            package var ambientCorpusIndexing: Bool = true
            package var localModelID: String = MaryLocalEngine.defaultModelID
            package var sttBackend: STTBackend = .apple
            package var ttsBackend: TTSBackend = .seer
            /// On-device Kokoro voice (bundle voices/). Never a hosted character — see seerVoice.
            package var voice: String = "af_heart"
            /// Hosted VoiceCharacter slug (`fr_marie`). Separate from `voice` — different namespaces.
            package var seerVoice: String = VoiceCharacter.marie.id
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

            // Seer/Totem local stack. Chat runs in seer mode whenever
            // seerEnabled and the stack + sign-in are up; otherwise the
            // engine-only legacy path carries the turn.
            package var seerEnabled: Bool = true
            package var autoStartServers: Bool = true
            package var seerCheckoutPath: String = ServerSpec.Defaults.seerCheckoutPath
            package var totemCheckoutPath: String = ServerSpec.Defaults.totemCheckoutPath
            package var seerPort: Int = ServerSpec.Defaults.seerPort
            package var seerGRPCPort: Int = ServerSpec.Defaults.seerGRPCPort
            package var totemPort: Int = ServerSpec.Defaults.totemPort
            package var totemGRPCPort: Int = ServerSpec.Defaults.totemGRPCPort
            /// The totem node UUID = the DB identity. Empty until first boot
            /// adopts Totem's persisted id (or mints one); after that it's
            /// pinned so the same DB loads every launch.
            package var totemNodeID: String = ""
            package var seerEmail: String = ServerSpec.Defaults.seerEmail
            package var seerPassword: String = ServerSpec.Defaults.seerPassword
            /// Graph-extraction backend Totem launches with. "mistral" by
            /// default: the mlx default silently degrades to keyword-only
            /// when the build lacks a metallib.
            package var totemGraphBackend: String = ServerSpec.Defaults.totemGraphBackend
            package var fleetCheckoutPath: String = ServerSpec.Defaults.fleetCheckoutPath
            package var fleetPort: Int = ServerSpec.Defaults.fleetPort
            package var fleetGRPCPort: Int = ServerSpec.Defaults.fleetGRPCPort
            /// Whether Mary pushes its graph policy (custom ontology kinds,
            /// co-mention edges) to Totem after boot.
            package var totemGraphPolicyManaged: Bool = true
            /// Chat model sent to Seer; empty = Seer's default (Mistral).
            /// The user's lever on thinking-model first-token latency.
            package var seerChatModel: String = ""
            /// Which route carries Seer-mode turns: classic SSE + /v1/speak,
            /// or the realtime WebSocket with server-side interleaved audio.
            package var seerTransport: SeerTransportChoice = .classic
            /// On-device coding agent. Off until Settings downloads a model
            /// and selects it — Hub fetch, never vendored weights.
            package var codingAgentEnabled: Bool = false
            package var codingAgentModelID: String = MaryCodingEngine.defaultModelID
            /// Lane-style choice for pair-coding synthesis. Local by default;
            /// hosted uses Seer's `/v1/code/complete` and never a Hub id.
            package var codingEngine: LLMEngineChoice = .local
            /// How long an ordinary Skill may stay running (1…20 s). Named
            /// build/test bindings keep their own ceilings.
            package var skillRunTimeoutSeconds: Double = 2

            enum CodingKeys: String, CodingKey {
                case ambientCorpusIndexing
                case llmEngine, skillEngine, localModelID, sttBackend, ttsBackend, voice, seerVoice, speechStyle, vad,
                     projects, customPronunciations, enabledPlugins, disabledPlugins,
                     historyMessageLimit, wakeWordEnabled
                case seerEnabled, autoStartServers, seerCheckoutPath, totemCheckoutPath, seerPort, seerGRPCPort, totemPort, totemGRPCPort, totemNodeID, seerEmail, seerPassword, totemGraphBackend, fleetCheckoutPath, fleetPort, fleetGRPCPort, totemGraphPolicyManaged, seerChatModel, seerTransport
                case codingAgentEnabled, codingAgentModelID, codingEngine
                case skillRunTimeoutSeconds
            }

            package init() {}

            /// Tolerant decode: a missing key must NEVER fail the restore —
            /// a thrown decode makes Granite re-seed defaults (Gita's rule).
            package init(from decoder: Decoder) throws {
                self.init()
                let c = try decoder.container(keyedBy: CodingKeys.self)
                llmEngine = try c.decodeIfPresent(LLMEngineChoice.self, forKey: .llmEngine) ?? .hosted
                skillEngine = try c.decodeIfPresent(LLMEngineChoice.self, forKey: .skillEngine) ?? .local
                ambientCorpusIndexing = try c.decodeIfPresent(
                    Bool.self, forKey: .ambientCorpusIndexing) ?? true
                localModelID = try c.decodeIfPresent(String.self, forKey: .localModelID) ?? MaryLocalEngine.defaultModelID

                sttBackend = try c.decodeIfPresent(STTBackend.self, forKey: .sttBackend) ?? .apple
                ttsBackend = try c.decodeIfPresent(TTSBackend.self, forKey: .ttsBackend) ?? .seer
                voice = try c.decodeIfPresent(String.self, forKey: .voice) ?? "af_heart"
                seerVoice = try c.decodeIfPresent(String.self, forKey: .seerVoice)
                    ?? VoiceCharacter.marie.id
                // Migrate hosted character out of the on-device voice slot.
                if let hosted = VoiceCharacter.all.first(where: { $0.id == voice }) {
                    if !c.contains(.seerVoice) { seerVoice = hosted.id }
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
                seerEnabled = try c.decodeIfPresent(Bool.self, forKey: .seerEnabled) ?? true
                autoStartServers = try c.decodeIfPresent(Bool.self, forKey: .autoStartServers) ?? true
                let storedSeerCheckoutPath = try c.decodeIfPresent(
                    String.self, forKey: .seerCheckoutPath)
                    ?? ServerSpec.Defaults.seerCheckoutPath
                seerCheckoutPath = ServerSpec.Defaults.migratedSeerCheckoutPath(
                    storedSeerCheckoutPath)
                totemCheckoutPath = try c.decodeIfPresent(String.self, forKey: .totemCheckoutPath) ?? ServerSpec.Defaults.totemCheckoutPath
                seerPort = try c.decodeIfPresent(Int.self, forKey: .seerPort) ?? ServerSpec.Defaults.seerPort
                seerGRPCPort = try c.decodeIfPresent(Int.self, forKey: .seerGRPCPort) ?? ServerSpec.Defaults.seerGRPCPort
                totemPort = try c.decodeIfPresent(Int.self, forKey: .totemPort) ?? ServerSpec.Defaults.totemPort
                totemGRPCPort = try c.decodeIfPresent(Int.self, forKey: .totemGRPCPort) ?? ServerSpec.Defaults.totemGRPCPort
                totemNodeID = try c.decodeIfPresent(String.self, forKey: .totemNodeID) ?? ""
                seerEmail = try c.decodeIfPresent(String.self, forKey: .seerEmail) ?? ServerSpec.Defaults.seerEmail
                seerPassword = try c.decodeIfPresent(String.self, forKey: .seerPassword) ?? ServerSpec.Defaults.seerPassword
                totemGraphBackend = try c.decodeIfPresent(String.self, forKey: .totemGraphBackend) ?? ServerSpec.Defaults.totemGraphBackend
                fleetCheckoutPath = try c.decodeIfPresent(String.self, forKey: .fleetCheckoutPath) ?? ServerSpec.Defaults.fleetCheckoutPath
                fleetPort = try c.decodeIfPresent(Int.self, forKey: .fleetPort) ?? ServerSpec.Defaults.fleetPort
                fleetGRPCPort = try c.decodeIfPresent(Int.self, forKey: .fleetGRPCPort) ?? ServerSpec.Defaults.fleetGRPCPort
                totemGraphPolicyManaged = try c.decodeIfPresent(Bool.self, forKey: .totemGraphPolicyManaged) ?? true
                seerChatModel = try c.decodeIfPresent(String.self, forKey: .seerChatModel) ?? ""
                seerTransport = try c.decodeIfPresent(SeerTransportChoice.self, forKey: .seerTransport) ?? .classic
                codingAgentEnabled = try c.decodeIfPresent(Bool.self, forKey: .codingAgentEnabled) ?? false
                codingAgentModelID = try c.decodeIfPresent(String.self, forKey: .codingAgentModelID)
                    ?? MaryCodingEngine.defaultModelID
                codingEngine = try c.decodeIfPresent(LLMEngineChoice.self, forKey: .codingEngine) ?? .local
                skillRunTimeoutSeconds = AbilityRuntime.clampedOrdinarySkillTimeout(
                    try c.decodeIfPresent(Double.self, forKey: .skillRunTimeoutSeconds) ?? 2)
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
