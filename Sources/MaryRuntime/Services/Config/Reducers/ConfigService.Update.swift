import MaryAmbient
import MaryBrain
import MaryPlugin
import MaryVoice
import Foundation
import Granite

extension ConfigService {
    /// One settings mutation — non-nil fields apply. The Settings sheet fires
    /// this per control change; engine/voice swaps are applied by the caller
    /// through MaryRuntime.
    package struct Update: GraniteReducer {
        package typealias Center = ConfigService.Center
        package init() {}

        package struct Meta: GranitePayload {
        package init(
            llmEngine: LLMEngineChoice? = nil,
            localModelID: String? = nil,
            sttBackend: STTBackend? = nil,
            ttsBackend: TTSBackend? = nil,
            voice: String? = nil,
            seerVoice: String? = nil,
            speechStyle: SpeechStyleSelection? = nil,
            vad: VADConfig? = nil,
            projects: [ProjectRef]? = nil,
            customPronunciations: [PronunciationRef]? = nil,
            disabledPlugins: [String]? = nil,
            historyMessageLimit: Int? = nil,
            behavioralRecording: Bool? = nil,
            ambientCorpusIndexing: Bool? = nil,
            wakeWordEnabled: Bool? = nil,
            seerEnabled: Bool? = nil,
            autoStartServers: Bool? = nil,
            seerCheckoutPath: String? = nil,
            totemCheckoutPath: String? = nil,
            seerPort: Int? = nil,
            seerGRPCPort: Int? = nil,
            totemPort: Int? = nil,
            totemGRPCPort: Int? = nil,
            totemNodeID: String? = nil,
            seerEmail: String? = nil,
            seerPassword: String? = nil,
            totemGraphBackend: String? = nil,
            fleetCheckoutPath: String? = nil,
            fleetPort: Int? = nil,
            fleetGRPCPort: Int? = nil,
            totemGraphPolicyManaged: Bool? = nil,
            seerChatModel: String? = nil,
            seerTransport: SeerTransportChoice? = nil,
            codingAgentEnabled: Bool? = nil,
            codingAgentModelID: String? = nil,
            skillRunTimeoutSeconds: Double? = nil
        ) {
            self.llmEngine = llmEngine
            self.localModelID = localModelID
            self.sttBackend = sttBackend
            self.ttsBackend = ttsBackend
            self.voice = voice
            self.seerVoice = seerVoice
            self.speechStyle = speechStyle
            self.vad = vad
            self.projects = projects
            self.customPronunciations = customPronunciations
            self.disabledPlugins = disabledPlugins
            self.historyMessageLimit = historyMessageLimit
            self.behavioralRecording = behavioralRecording
            self.ambientCorpusIndexing = ambientCorpusIndexing
            self.wakeWordEnabled = wakeWordEnabled
            self.seerEnabled = seerEnabled
            self.autoStartServers = autoStartServers
            self.seerCheckoutPath = seerCheckoutPath
            self.totemCheckoutPath = totemCheckoutPath
            self.seerPort = seerPort
            self.seerGRPCPort = seerGRPCPort
            self.totemPort = totemPort
            self.totemGRPCPort = totemGRPCPort
            self.totemNodeID = totemNodeID
            self.seerEmail = seerEmail
            self.seerPassword = seerPassword
            self.totemGraphBackend = totemGraphBackend
            self.fleetCheckoutPath = fleetCheckoutPath
            self.fleetPort = fleetPort
            self.fleetGRPCPort = fleetGRPCPort
            self.totemGraphPolicyManaged = totemGraphPolicyManaged
            self.seerChatModel = seerChatModel
            self.seerTransport = seerTransport
            self.codingAgentEnabled = codingAgentEnabled
            self.codingAgentModelID = codingAgentModelID
            self.skillRunTimeoutSeconds = skillRunTimeoutSeconds
        }
            package var llmEngine: LLMEngineChoice? = nil
            package var localModelID: String? = nil
            package var sttBackend: STTBackend? = nil
            package var ttsBackend: TTSBackend? = nil
            package var voice: String? = nil
            package var seerVoice: String? = nil
            package var speechStyle: SpeechStyleSelection? = nil
            package var vad: VADConfig? = nil
            package var projects: [ProjectRef]? = nil
            package var customPronunciations: [PronunciationRef]? = nil
            /// Which plugins the user switched off. The enabled roster is
            /// derived from this, never sent.
            package var disabledPlugins: [String]? = nil
            package var historyMessageLimit: Int?
        package var behavioralRecording: Bool? = nil
        package var ambientCorpusIndexing: Bool? = nil
            package var wakeWordEnabled: Bool? = nil
            package var seerEnabled: Bool? = nil
            package var autoStartServers: Bool? = nil
            package var seerCheckoutPath: String? = nil
            package var totemCheckoutPath: String? = nil
            package var seerPort: Int? = nil
            package var seerGRPCPort: Int? = nil
            package var totemPort: Int? = nil
            package var totemGRPCPort: Int? = nil
            package var totemNodeID: String? = nil
            package var seerEmail: String? = nil
            package var seerPassword: String? = nil
            package var totemGraphBackend: String? = nil
            package var fleetCheckoutPath: String? = nil
            package var fleetPort: Int? = nil
            package var fleetGRPCPort: Int? = nil
            package var totemGraphPolicyManaged: Bool? = nil
            package var seerChatModel: String? = nil
            package var seerTransport: SeerTransportChoice? = nil
            package var codingAgentEnabled: Bool? = nil
            package var codingAgentModelID: String? = nil
            package var skillRunTimeoutSeconds: Double? = nil
        }

        @Payload package var meta: Meta?

        package func reduce(state: inout Center.State) {
            guard let meta else { return }
            if let value = meta.llmEngine { state.llmEngine = value }
            if let value = meta.localModelID, !value.isEmpty { state.localModelID = value }
            if let value = meta.sttBackend { state.sttBackend = value }
            if let value = meta.ttsBackend { state.ttsBackend = value }
            if let value = meta.voice, !value.isEmpty { state.voice = value }
            if let value = meta.seerVoice, !value.isEmpty { state.seerVoice = value }
            if let value = meta.speechStyle { state.speechStyle = value }
            if let value = meta.vad { state.vad = value }
            if let value = meta.projects { state.projects = value }
            if let value = meta.customPronunciations { state.customPronunciations = value }
                if let value = meta.disabledPlugins {
                state.disabledPlugins = value
                state.enabledPlugins = MaryAdapterCatalog.adapters().map(\.name)
                    .filter { !state.disabledPlugins.contains($0) }
            }
            // Empty is meaningful here (clears the custom id), unlike localModelID.
            // Empty is meaningful here too: custom with no alias follows config.
            if let value = meta.historyMessageLimit, value >= 4 { state.historyMessageLimit = value }
            if let value = meta.behavioralRecording { state.behavioralRecording = value }
            if let value = meta.ambientCorpusIndexing { state.ambientCorpusIndexing = value }
            if let value = meta.wakeWordEnabled { state.wakeWordEnabled = value }
            if let value = meta.seerEnabled { state.seerEnabled = value }
            if let value = meta.autoStartServers { state.autoStartServers = value }
            if let value = meta.seerCheckoutPath, !value.isEmpty { state.seerCheckoutPath = value }
            if let value = meta.totemCheckoutPath, !value.isEmpty { state.totemCheckoutPath = value }
            if let value = meta.seerPort, value > 0 { state.seerPort = value }
            if let value = meta.seerGRPCPort, value > 0 { state.seerGRPCPort = value }
            if let value = meta.totemPort, value > 0 { state.totemPort = value }
            if let value = meta.totemGRPCPort, value > 0 { state.totemGRPCPort = value }
            // Empty is meaningful (falls back to Totem's persisted identity).
            if let value = meta.totemNodeID { state.totemNodeID = value }
            if let value = meta.seerEmail, !value.isEmpty { state.seerEmail = value }
            if let value = meta.seerPassword, !value.isEmpty { state.seerPassword = value }
            if let value = meta.totemGraphBackend, !value.isEmpty { state.totemGraphBackend = value }
            if let value = meta.fleetCheckoutPath, !value.isEmpty { state.fleetCheckoutPath = value }
            if let value = meta.fleetPort, value > 0 { state.fleetPort = value }
            if let value = meta.fleetGRPCPort, value > 0 { state.fleetGRPCPort = value }
            if let value = meta.totemGraphPolicyManaged { state.totemGraphPolicyManaged = value }
            // Empty is meaningful (reverts to Seer's default model).
            if let value = meta.seerChatModel { state.seerChatModel = value }
            if let value = meta.seerTransport { state.seerTransport = value }
            if let value = meta.codingAgentEnabled { state.codingAgentEnabled = value }
            if let value = meta.codingAgentModelID, !value.isEmpty {
                state.codingAgentModelID = value
            }
            if let value = meta.skillRunTimeoutSeconds {
                state.skillRunTimeoutSeconds = AbilityRuntime.clampedOrdinarySkillTimeout(value)
            }
        }
    }
}
