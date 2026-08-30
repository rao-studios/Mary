//
//  AffordancePlugin.swift
//  MaryAdapter
//
//  WHAT: One skill for every family — act on what the screen is offering.
//  IN:   composition root (beside looking / project-corpus)
//  OUT:  AffordanceRecipes.actOnScreen
//  PIN:  Appended, not catalogued — LookingPlugin's shape. Not a browsing
//        command: macUI locators need an exact id/title a skip button lacks.
//

import Foundation

public struct AffordancePlugin: MaryAdapter {

    public let name = "affordances"
    public let summary = "Act on whatever the screen is currently offering — press the control that accomplishes what the user asked, in any application."

    public init() {}

    public var promptFragment: String? { nil }
    public var abilities: Set<AbilityID> { [] }
    /// Empty: an alias names an application, and this names none.
    /// PIN: "screen" would compete with looking.
    public var applicationAliases: Set<String> { [] }
    public var applicationIdentifiers: Set<String> { [] }
    public var targetedRead: (binding: String, parameter: String)? { nil }
    public var passageBacking: PassageBacking? { nil }

    public var adapterManifest: InstalledAdapterManifest {
        let adapterID = AdapterID("affordances")
        return InstalledAdapterManifest(
            adapterID: adapterID,
            title: "Affordances",
            transport: .native,
            operations: skillBindings.map { binding in
                InstalledAdapterBinding(
                    adapterID: adapterID,
                    operation: binding.name,
                    capabilities: ["screen.act"],
                    inputTypes: [],
                    outputTypes: [],
                    targetClasses: [])
            },
            supportedValueTypes: [])
    }

    public var skillBindings: [SkillBinding] {
        [
            SkillBinding(
                name: "act_on_screen",
                description: "Do what the user asked by pressing the control on screen that accomplishes it — skip an ad, go full screen, accept a banner, dismiss a dialog. Any application. Give their goal in their own words.",
                parameters: [
                    .init(name: "goal", type: "string",
                          description: "What they want done, in their own words — \"skip the ad\", \"make it full screen\", \"accept cookies\".",
                          required: true),
                ],
                access: .tweak,
                backing: .native { arguments, _ in
                    await AffordanceRecipes.actOnScreen(
                        goal: arguments["goal"] ?? "")
                },
                spokenFailureHint: "check Accessibility in my Settings",
                stage: true),
        ]
    }
}
