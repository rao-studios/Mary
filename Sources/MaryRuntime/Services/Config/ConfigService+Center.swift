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
            /// HOSTED BY DEFAULT, because that is what the build already
            /// does: `seerEnabled` and `autoStartServers` both default true
            /// and the turn loop takes the Seer path whenever the server
            /// answers, so a fresh install that read "Local (on device)" was
            /// describing a turn that had gone to Seer.
            package var llmEngine: LLMEngineChoice = .hosted
            /// Ambient corpus indexing: when a unit settles in an application
            /// that declares a corpus, crawl its neighbourhood and remember
            /// the structure. On by default — it is how Mary learns the shape
            /// of your work — and nothing but declaration headers and
            /// generated summaries ever crosses into memory.
            package var ambientCorpusIndexing: Bool = true
            /// Whether sealed episodes reach disk. See `BehavioralStore`.
            package var behavioralRecording: Bool = true
            package var localModelID: String = MaryLocalEngine.defaultModelID
            package var sttBackend: STTBackend = .apple
            package var ttsBackend: TTSBackend = .seer
            /// THE ON-DEVICE VOICE, and only that: a Kokoro style-embedding
            /// name matching a file in the bundle's `voices/`. Never a hosted
            /// character — see `seerVoice`.
            package var voice: String = "af_heart"
            /// THE HOSTED CHARACTER, and only that: a `VoiceCharacter` slug
            /// (`fr_marie`) the Seer server renders itself.
            ///
            /// SEPARATE FIELDS BECAUSE THEY ARE SEPARATE NAMESPACES. One field
            /// served both, so choosing the Seer character wrote `fr_marie`
            /// into the slot boot hands to Kokoro — and the next launch died on
            /// `'fr_marie.json' not found`, an on-device file that never
            /// existed for a voice that only ever spoke from the server.
            package var seerVoice: String = VoiceCharacter.marie.id
            package var speechStyle: SpeechStyleSelection = .auto
            package var vad: VADConfig = .init()
            package var projects: [ProjectRef] = []
            package var customPronunciations: [PronunciationRef] = []
            /// THE PERSISTED TRUTH: which plugins the user switched OFF. Empty
            /// — the default, and the state of a fresh install — means every
            /// plugin the build ships is installed, including ones that ship
            /// after this file was last written. See
            /// `MaryAdapterCatalog.normalizedDisabledPluginIDs` for why this is
            /// a deviation list rather than a roster.
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
            /// "Hey Mary" standby. ON by default: while no session runs, a
            /// wake-only microphone listens for her name (everything else is
            /// discarded on-device), and "stop listening" ends a session by
            /// voice. The macOS mic indicator stays lit while armed — this
            /// toggle is the opt-out.
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
            /// Whether Mary pushes its graph policy (custom ontology kinds,
            /// co-mention edges) to Totem after boot.
            package var totemGraphPolicyManaged: Bool = true
            /// Chat model sent to Seer; empty = Seer's default (Mistral).
            /// The user's lever on thinking-model first-token latency.
            package var seerChatModel: String = ""
            /// Which route carries Seer-mode turns: classic SSE + /v1/speak,
            /// or the realtime WebSocket with server-side interleaved audio.
            package var seerTransport: SeerTransportChoice = .classic

            enum CodingKeys: String, CodingKey {
                case ambientCorpusIndexing
                case llmEngine, localModelID, sttBackend, ttsBackend, voice, seerVoice, speechStyle, vad,
                     projects, customPronunciations, enabledPlugins, disabledPlugins,
                     historyMessageLimit, wakeWordEnabled, behavioralRecording
                case seerEnabled, autoStartServers, seerCheckoutPath, totemCheckoutPath, seerPort, seerGRPCPort, totemPort, totemGRPCPort, totemNodeID, seerEmail, seerPassword, totemGraphBackend, totemGraphPolicyManaged, seerChatModel, seerTransport
            }

            package init() {}

            /// Tolerant decode: a missing key must NEVER fail the restore —
            /// a thrown decode makes Granite re-seed defaults (Gita's rule).
            package init(from decoder: Decoder) throws {
                self.init()
                let c = try decoder.container(keyedBy: CodingKeys.self)
                llmEngine = try c.decodeIfPresent(LLMEngineChoice.self, forKey: .llmEngine) ?? .hosted
                ambientCorpusIndexing = try c.decodeIfPresent(
                    Bool.self, forKey: .ambientCorpusIndexing) ?? true
                localModelID = try c.decodeIfPresent(String.self, forKey: .localModelID) ?? MaryLocalEngine.defaultModelID

                sttBackend = try c.decodeIfPresent(STTBackend.self, forKey: .sttBackend) ?? .apple
                ttsBackend = try c.decodeIfPresent(TTSBackend.self, forKey: .ttsBackend) ?? .seer
                voice = try c.decodeIfPresent(String.self, forKey: .voice) ?? "af_heart"
                seerVoice = try c.decodeIfPresent(String.self, forKey: .seerVoice)
                    ?? VoiceCharacter.marie.id
                // THE MIGRATION off the shared field. Every install written by
                // a build with one `voice` slot may hold a hosted character
                // there; left alone it boots Kokoro on a file that cannot
                // exist. Move it to the side it belongs on and give the
                // on-device engine its default back.
                if let hosted = VoiceCharacter.all.first(where: { $0.id == voice }) {
                    if !c.contains(.seerVoice) { seerVoice = hosted.id }
                    voice = Self().voice
                }

                speechStyle = try c.decodeIfPresent(SpeechStyleSelection.self, forKey: .speechStyle) ?? .auto
                vad = try c.decodeIfPresent(VADConfig.self, forKey: .vad) ?? .init()
                projects = try c.decodeIfPresent([ProjectRef].self, forKey: .projects) ?? []
                customPronunciations = try c.decodeIfPresent([PronunciationRef].self, forKey: .customPronunciations) ?? []
                // THE DEVIATION LIST, not an enabled roster. A plugin added
                // since the last write is INSTALLED rather than invisible,
                // which is the whole reason the stored form is what is turned
                // OFF: the alternative silently withholds every new capability
                // from anyone who has ever opened Settings.
                disabledPlugins = try c.decodeIfPresent(
                    [String].self, forKey: .disabledPlugins) ?? []
                enabledPlugins = MaryAdapterCatalog.adapters()
                    .map(\.name)
                    .filter { !disabledPlugins.contains($0) }
                historyMessageLimit = try c.decodeIfPresent(
                    Int.self, forKey: .historyMessageLimit) ?? 12
                // RECORDING IS ON BY DEFAULT AND OFF BY ONE SWITCH. See
                // `BehavioralStore` on what it writes and what off means.
                behavioralRecording = try c.decodeIfPresent(
                    Bool.self, forKey: .behavioralRecording) ?? true

                // THROUGH `String`, NOT THROUGH THE ENUM. `decodeIfPresent`
                // returns nil only for a MISSING key — a key that is present
                // with an unrecognized value still THROWS, and a throw here
                // re-seeds every default in this struct (see the note above).
                // So a build that once wrote a mode this build does not know
                // would cost the user their engine, voice, projects and server
                // paths all at once, on launch, silently.

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
                totemGraphPolicyManaged = try c.decodeIfPresent(Bool.self, forKey: .totemGraphPolicyManaged) ?? true
                seerChatModel = try c.decodeIfPresent(String.self, forKey: .seerChatModel) ?? ""
                seerTransport = try c.decodeIfPresent(SeerTransportChoice.self, forKey: .seerTransport) ?? .classic
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
