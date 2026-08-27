//
//  MaryLocalEngine.swift
//  MaryBrain
//
//  On-device Mistral over Frigate's MLX stack, modeled on Fleet's
//  FleetInference.ChatSession: an actor holds the non-Sendable ModelContext,
//  prepares UserInput(chat:tools:), and forwards the Generation stream.
//  Requires mlx.metallib next to the binary (see build-metallib.sh).
//

import Foundation
import MLXLLM
import MLXLMCommon

public actor MaryLocalEngine: InferenceEngine {

    /// ON-DEVICE. Nothing this engine is given leaves the machine, and the
    /// behavioral record says so on every episode it produced.
    public nonisolated var choice: LLMEngineChoice { .local }


    /// One MLX model instance; concurrent generate calls are not guaranteed
    /// safe — the brain serializes rounds for this engine only.
    public nonisolated var requiresExclusiveGeneration: Bool { true }

    /// Nemo over 7B-v0.3: it reliably emits native Mistral tool calls that
    /// Frigate's processor parses, where 7B narrates them in markdown.
    public static let defaultModelID = "mlx-community/Mistral-Nemo-Instruct-2407-4bit"

    private let modelID: String
    private var context: ModelContext?
    /// 0…1 while the first-use download runs (surfaced by Boot state).
    private(set) var downloadProgress: Double = 1.0

    public nonisolated let displayName: String

    public init(modelID: String = MaryLocalEngine.defaultModelID) {
        self.modelID = modelID
        self.displayName = "On-device (\(modelID.components(separatedBy: "/").last ?? modelID))"
    }

    // MARK: - InferenceEngine

    public func warmup() async throws {
        _ = try await loadedContext()
    }

    public nonisolated func stream(
        system: String,
        history: [BrainTurn],
        skills: [ModelSkillSchema]
    ) -> AsyncThrowingStream<EngineEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.streamRound(
                        system: system, history: history, skills: skills,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Private

    private func streamRound(
        system: String,
        history: [BrainTurn],
        skills: [ModelSkillSchema],
        continuation: AsyncThrowingStream<EngineEvent, Error>.Continuation
    ) async throws {
        let ctx = try await loadedContext()

        // Frigate's ToolCallProcessor parses the mlx-lm default wrapper; a 7B
        // Mistral needs the contract spelled out or it narrates the call in
        // markdown instead of making it.
        var systemText = system
        if !skills.isEmpty {
            let roster = skills
                .map { "\($0.name) — \($0.description)" }
                .joined(separator: "\n")
            systemText += """


            Your Skills, by exact name (never invent other names):
            \(roster)

            To perform an action, respond with ONLY this exact format on its own — \
            no other words, no code fences:
            <tool_call>{"name": "tool_name", "arguments": {"param": "value"}}</tool_call>
            For plain conversation, answer normally without tags.
            """
        }

        // Mistral-family Jinja templates demand strict user/assistant
        // alternation and reject bare "tool" roles. Tool results become
        // labeled user text, empty assistant turns disappear (a tool-only
        // round has no prose), and adjacent same-role messages merge.
        var mapped: [(isUser: Bool, text: String)] = []
        for turn in history {
            let entry: (Bool, String)
            switch turn.role {
            case .user:
                entry = (true, turn.text)
            case .assistant:
                guard !turn.text.isEmpty else { continue }
                entry = (false, turn.text)
            case .skillResult:
                entry = (true, "[skill result — \(turn.skillName ?? "skill")]: \(turn.text)")
            }
            if let last = mapped.last, last.isUser == entry.0 {
                mapped[mapped.count - 1].text += "\n\n" + entry.1
            } else {
                mapped.append(entry)
            }
        }

        var messages: [Chat.Message] = [.system(systemText)]
        for entry in mapped {
            messages.append(entry.isUser ? .user(entry.text) : .assistant(entry.text))
        }

        let input = try await ctx.processor.prepare(
            input: UserInput(
                chat: messages,
                tools: skills.isEmpty ? nil : skills.map(Self.toolSpec(from:))
            )
        )
        let stream = try MLXLMCommon.generate(
            input: input,
            parameters: GenerateParameters(maxTokens: 800),
            context: ctx
        )

        // Mistral models rarely use the <tool_call> tags Frigate's processor
        // parses. They emit either the native `[TOOL_CALLS] [{...}]` wire
        // format or — under big Skill rosters — a fenced/bare/name-prefixed
        // JSON object. The shared interceptor withholds text while the reply
        // could still be any of those, parses at end of round, and never
        // surfaces raw JSON (or the hallucinated chatter models append).
        var interceptor = SkillCallTextInterceptor(
            knownSkillNames: Set(skills.map(\.name)))

        for await item in stream {
            if Task.isCancelled { break }
            switch item {
            case .chunk(let text):
                let speakable = interceptor.ingest(text)
                if !speakable.isEmpty {
                    continuation.yield(.text(speakable))
                }
            case .toolCall(let call):
                let argumentsJSON: String
                if let data = try? JSONSerialization.data(
                    withJSONObject: call.function.arguments.mapValues { $0.anyValue }),
                    let json = String(data: data, encoding: .utf8) {
                    argumentsJSON = json
                } else {
                    argumentsJSON = "{}"
                }
                continuation.yield(.skillInvocation(ModelSkillInvocation(
                    id: "local-\(UUID().uuidString.prefix(8))",
                    name: call.function.name,
                    argumentsJSON: argumentsJSON
                )))
            case .info:
                break
            }
        }

        switch interceptor.finish() {
        case .speech(let text):
            if !text.isEmpty { continuation.yield(.text(text)) }
        case .skillInvocations(let invocations):
            for invocation in invocations {
                continuation.yield(.skillInvocation(invocation))
            }
        case .dropped, .nothing:
            break
        }
        continuation.yield(.done)
    }

    // MARK: - Interception shims
    //
    // The parsing machinery moved to the shared SkillCallTextInterceptor
    // (TinkerInklingEngine needs it too). These forwarders keep the pinned
    // MistralNativeToolCallTests compiling unmodified — the parity proof.

    static func strippingToolResultEcho(_ text: String) -> String {
        SkillCallTextInterceptor.strippingToolResultEcho(text)
    }

    static func parseLooseToolCalls(from text: String) -> [ModelSkillInvocation] {
        SkillCallTextInterceptor.parseLooseToolCalls(from: text)
    }

    static func parseNativeToolCalls(from text: String) -> [ModelSkillInvocation] {
        SkillCallTextInterceptor.parseNativeToolCalls(from: text)
    }

    /// THE ON-DEVICE ATTACHMENT POINT, named because it is asked about.
    ///
    /// If Mary ever runs a fine-tuned or LoRA-adapted model — a small router
    /// that reads the utterance and the ambient store to build a sharper route
    /// before the prompt is assembled — this `loadModel` call is where the
    /// adapter attaches, and it has to live behind this package's wall:
    /// Frigate's MLX and its vendored transformers are consumed ONLY through
    /// MaryBrain, under the module-alias map in `Package.swift`, because a
    /// second consumer without the identical map collides with WhisperKit's
    /// copy.
    ///
    /// NOTE THE NAME: "Fleet" is a sibling product this app ported its palette
    /// and Sendable precedent from, not a package here — there is nothing to
    /// integrate under that name. The on-device stack is Frigate/MLX, and it
    /// is this file.
    ///
    /// What such a router may and may not decide is in
    /// `docs/PROMPT-ASSEMBLY.md` §3 and on `AmbientRoute`. Nothing is
    /// implemented; this comment exists so the seam is not closed by accident.
    private func loadedContext() async throws -> ModelContext {
        if let context { return context }
        downloadProgress = 0
        let ctx = try await MLXLMCommon.loadModel(
            configuration: ModelConfiguration(id: modelID),
            progressHandler: { [weak self] progress in
                let fraction = progress.fractionCompleted
                Task { await self?.setDownloadProgress(fraction) }
            }
        )
        downloadProgress = 1.0
        context = ctx
        return ctx
    }

    private func setDownloadProgress(_ value: Double) {
        downloadProgress = value
    }

    /// Render a neutral ModelSkillSchema as Frigate's ToolSpec (a typealias of
    /// `[String: any Sendable]` in its Tokenizers module) — the exact
    /// OpenAI-style function shape Tool.init builds.
    static func toolSpec(from schema: ModelSkillSchema) -> [String: any Sendable] {
        var properties = [String: any Sendable]()
        var required = [String]()
        for parameter in schema.parameters {
            var spec: [String: any Sendable] = [
                "type": parameter.type,
                "description": parameter.description,
            ]
            if let enumValues = parameter.enumValues {
                spec["enum"] = enumValues
            }
            if let minimum = parameter.minimum {
                spec["minimum"] = minimum
            }
            if let maximum = parameter.maximum {
                spec["maximum"] = maximum
            }
            properties[parameter.name] = spec
            if parameter.required { required.append(parameter.name) }
        }
        return [
            "type": "function",
            "function": [
                "name": schema.name,
                "description": schema.description,
                "parameters": [
                    "type": "object",
                    "properties": properties,
                    "required": required,
                ] as [String: any Sendable],
            ] as [String: any Sendable],
        ]
    }
}
