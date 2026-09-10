//
//  LookingPlugin.swift
//  MaryPlugin
//
//  WHAT: Glance at the attended screen region and describe it.
//  IN:   brain capture + vision (injected at install)
//  OUT:  SkillBinding (look) → description text
//  PIN:  Appended faculty, not a catalogued app. Pixels never persist;
//        description is the only survivor.
//

import Foundation

public struct LookingPlugin: MaryAdapter {
    public typealias Perform = @Sendable (_ query: String?) async -> SkillOutcome

    public let name = "looking"
    public let summary = "Look at what the user is viewing on screen when asked — one ephemeral glance around their attention, described in words."

    private let perform: Perform

    public init(perform: @escaping Perform) {
        self.perform = perform
    }

    public var promptFragment: String? { nil }
    public var abilities: Set<AbilityID> { [] }
    public var applicationAliases: Set<String> { ["looking", "screen", "sight"] }
    public var applicationIdentifiers: Set<String> { [] }
    public var targetedRead: (binding: String, parameter: String)? { nil }
    public var servedAttention: AmbientAttention? { nil }

    public var adapterManifest: InstalledAdapterManifest {
        let adapterID = AdapterID("looking")
        return InstalledAdapterManifest(
            adapterID: adapterID,
            title: "Looking",
            transport: .native,
            operations: skillBindings.map { binding in
                InstalledAdapterBinding(
                    adapterID: adapterID,
                    operation: binding.name,
                    capabilities: ["screen.look"],
                    inputTypes: [],
                    outputTypes: ["looking.description"],
                    targetClasses: [])
            },
            supportedValueTypes: ["looking.description"])
    }

    public var skillBindings: [SkillBinding] {
        let perform = perform
        return [
            SkillBinding(
                name: "look_at_screen",
                description: "Look at what the user is viewing on screen right now — an image, video, chart, page, or app in ANY application — and describe it. Use whenever the user says \"look at this\", \"can you see this\", or \"what do you think of this\". One ephemeral glance; nothing is saved.",
                parameters: [
                    .init(name: "query", type: "string",
                          description: "What the user wants understood, in their words — \"the video\", \"this diagram\", or their question about it.",
                          required: false),
                ],
                access: .read,
                backing: .native { arguments, _ in
                    await perform(arguments["query"])
                },
                stage: false),
        ]
    }
}
