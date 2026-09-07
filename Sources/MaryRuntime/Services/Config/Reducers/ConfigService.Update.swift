//
//  ConfigService.Update.swift
//  MaryRuntime
//
//  WHAT: One settings mutation — non-nil fields apply.
//  IN:   Settings sheet (per control). Engine/voice swaps applied by caller.
//  OUT:  ConfigService.Center.State
//

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
            skillEngine: LLMEngineChoice? = nil,
            lifeMode: LifeMode? = nil,
            lifeTurnDisciplines: [String]? = nil,
            sttBackend: STTBackend? = nil,
            ttsBackend: TTSBackend? = nil,
            voice: String? = nil,
            sewnVoice: String? = nil,
            speechStyle: SpeechStyleSelection? = nil,
            vad: VADConfig? = nil,
            projects: [ProjectRef]? = nil,
            customPronunciations: [PronunciationRef]? = nil,
            disabledPlugins: [String]? = nil,
            historyMessageLimit: Int? = nil,
            ambientCorpusIndexing: Bool? = nil,
            wakeWordEnabled: Bool? = nil,
            sewnEnabled: Bool? = nil,
            autoStartServers: Bool? = nil,
            sewnCheckoutPath: String? = nil,
            threadCheckoutPath: String? = nil,
            sewnPort: Int? = nil,
            sewnGRPCPort: Int? = nil,
            threadPort: Int? = nil,
            threadGRPCPort: Int? = nil,
            threadNodeID: String? = nil,
            sewnEmail: String? = nil,
            sewnPassword: String? = nil,
            threadGraphBackend: String? = nil,
            fleetCheckoutPath: String? = nil,
            fleetPort: Int? = nil,
            fleetGRPCPort: Int? = nil,
            threadGraphPolicyManaged: Bool? = nil,
            sewnChatModel: String? = nil,
            sewnTransport: SewnTransportChoice? = nil,
            codingAgentEnabled: Bool? = nil,
            codingEngine: LLMEngineChoice? = nil,
            skillRunTimeoutSeconds: Double? = nil,
            modelCallPriceUSD: Double? = nil
        ) {
            self.llmEngine = llmEngine
            self.skillEngine = skillEngine
            self.lifeMode = lifeMode
            self.lifeTurnDisciplines = lifeTurnDisciplines
            self.sttBackend = sttBackend
            self.ttsBackend = ttsBackend
            self.voice = voice
            self.sewnVoice = sewnVoice
            self.speechStyle = speechStyle
            self.vad = vad
            self.projects = projects
            self.customPronunciations = customPronunciations
            self.disabledPlugins = disabledPlugins
            self.historyMessageLimit = historyMessageLimit
            self.ambientCorpusIndexing = ambientCorpusIndexing
            self.wakeWordEnabled = wakeWordEnabled
            self.sewnEnabled = sewnEnabled
            self.autoStartServers = autoStartServers
            self.sewnCheckoutPath = sewnCheckoutPath
            self.threadCheckoutPath = threadCheckoutPath
            self.sewnPort = sewnPort
            self.sewnGRPCPort = sewnGRPCPort
            self.threadPort = threadPort
            self.threadGRPCPort = threadGRPCPort
            self.threadNodeID = threadNodeID
            self.sewnEmail = sewnEmail
            self.sewnPassword = sewnPassword
            self.threadGraphBackend = threadGraphBackend
            self.fleetCheckoutPath = fleetCheckoutPath
            self.fleetPort = fleetPort
            self.fleetGRPCPort = fleetGRPCPort
            self.threadGraphPolicyManaged = threadGraphPolicyManaged
            self.sewnChatModel = sewnChatModel
            self.sewnTransport = sewnTransport
            self.codingAgentEnabled = codingAgentEnabled
            self.codingEngine = codingEngine
            self.skillRunTimeoutSeconds = skillRunTimeoutSeconds
            self.modelCallPriceUSD = modelCallPriceUSD
        }
            package var llmEngine: LLMEngineChoice? = nil
            package var skillEngine: LLMEngineChoice? = nil
            package var lifeMode: LifeMode? = nil
            package var lifeTurnDisciplines: [String]? = nil
            package var sttBackend: STTBackend? = nil
            package var ttsBackend: TTSBackend? = nil
            package var voice: String? = nil
            package var sewnVoice: String? = nil
            package var speechStyle: SpeechStyleSelection? = nil
            package var vad: VADConfig? = nil
            package var projects: [ProjectRef]? = nil
            package var customPronunciations: [PronunciationRef]? = nil
            /// Which plugins the user switched off. The enabled roster is
            /// derived from this, never sent.
            package var disabledPlugins: [String]? = nil
            package var historyMessageLimit: Int?
        package var ambientCorpusIndexing: Bool? = nil
            package var wakeWordEnabled: Bool? = nil
            package var sewnEnabled: Bool? = nil
            package var autoStartServers: Bool? = nil
            package var sewnCheckoutPath: String? = nil
            package var threadCheckoutPath: String? = nil
            package var sewnPort: Int? = nil
            package var sewnGRPCPort: Int? = nil
            package var threadPort: Int? = nil
            package var threadGRPCPort: Int? = nil
            package var threadNodeID: String? = nil
            package var sewnEmail: String? = nil
            package var sewnPassword: String? = nil
            package var threadGraphBackend: String? = nil
            package var fleetCheckoutPath: String? = nil
            package var fleetPort: Int? = nil
            package var fleetGRPCPort: Int? = nil
            package var threadGraphPolicyManaged: Bool? = nil
            package var sewnChatModel: String? = nil
            package var sewnTransport: SewnTransportChoice? = nil
            package var codingAgentEnabled: Bool? = nil
            package var codingEngine: LLMEngineChoice? = nil
            package var skillRunTimeoutSeconds: Double? = nil
            package var modelCallPriceUSD: Double? = nil
        }

        @Payload package var meta: Meta?

        package func reduce(state: inout Center.State) {
            guard let meta else { return }
            if let value = meta.llmEngine { state.llmEngine = value }
            if let value = meta.skillEngine { state.skillEngine = value }
            if let value = meta.lifeMode { state.lifeMode = value }
            if let value = meta.lifeTurnDisciplines { state.lifeTurnDisciplines = value }
            if let value = meta.sttBackend { state.sttBackend = value }
            if let value = meta.ttsBackend { state.ttsBackend = value }
            if let value = meta.voice, !value.isEmpty { state.voice = value }
            if let value = meta.sewnVoice, !value.isEmpty { state.sewnVoice = value }
            if let value = meta.speechStyle { state.speechStyle = value }
            if let value = meta.vad { state.vad = value }
            if let value = meta.projects { state.projects = value }
            if let value = meta.customPronunciations { state.customPronunciations = value }
                if let value = meta.disabledPlugins {
                state.disabledPlugins = value
                state.enabledPlugins = MaryAdapterCatalog.adapters().map(\.name)
                    .filter { !state.disabledPlugins.contains($0) }
            }
            // Empty is meaningful here too: custom with no alias follows config.
            if let value = meta.historyMessageLimit, value >= 4 { state.historyMessageLimit = value }
            if let value = meta.ambientCorpusIndexing { state.ambientCorpusIndexing = value }
            if let value = meta.wakeWordEnabled { state.wakeWordEnabled = value }
            if let value = meta.sewnEnabled { state.sewnEnabled = value }
            if let value = meta.autoStartServers { state.autoStartServers = value }
            if let value = meta.sewnCheckoutPath, !value.isEmpty { state.sewnCheckoutPath = value }
            if let value = meta.threadCheckoutPath, !value.isEmpty { state.threadCheckoutPath = value }
            if let value = meta.sewnPort, value > 0 { state.sewnPort = value }
            if let value = meta.sewnGRPCPort, value > 0 { state.sewnGRPCPort = value }
            if let value = meta.threadPort, value > 0 { state.threadPort = value }
            if let value = meta.threadGRPCPort, value > 0 { state.threadGRPCPort = value }
            // Empty is meaningful (falls back to Thread's persisted identity).
            if let value = meta.threadNodeID { state.threadNodeID = value }
            if let value = meta.sewnEmail, !value.isEmpty { state.sewnEmail = value }
            if let value = meta.sewnPassword, !value.isEmpty { state.sewnPassword = value }
            if let value = meta.threadGraphBackend, !value.isEmpty { state.threadGraphBackend = value }
            if let value = meta.fleetCheckoutPath, !value.isEmpty { state.fleetCheckoutPath = value }
            if let value = meta.fleetPort, value > 0 { state.fleetPort = value }
            if let value = meta.fleetGRPCPort, value > 0 { state.fleetGRPCPort = value }
            if let value = meta.threadGraphPolicyManaged { state.threadGraphPolicyManaged = value }
            // Empty is meaningful (reverts to Sewn's default model).
            if let value = meta.sewnChatModel { state.sewnChatModel = value }
            if let value = meta.sewnTransport { state.sewnTransport = value }
            if let value = meta.codingAgentEnabled { state.codingAgentEnabled = value }
            if let value = meta.codingEngine { state.codingEngine = value }
            if let value = meta.modelCallPriceUSD, value >= 0 {
                state.modelCallPriceUSD = value
            }
            if let value = meta.skillRunTimeoutSeconds {
                state.skillRunTimeoutSeconds = AbilityRuntime.clampedOrdinarySkillTimeout(value)
            }
        }
    }
}
