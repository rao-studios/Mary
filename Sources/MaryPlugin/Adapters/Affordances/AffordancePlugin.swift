//
//  AffordancePlugin.swift
//  MaryAdapter
//
//  ONE SKILL FOR EVERY FAMILY: act on what the screen is offering.
//
//  APPENDED, NOT CATALOGUED — `LookingPlugin`'s shape, for the same reason.
//  What is on screen is not a registered application's property, so this
//  declares no bundle identifier, no alias that could claim one, no
//  `AmbientWorld` case, and no Settings toggle. It is composed in beside
//  `looking` and the document-corpus adapter at the composition root and
//  reserved there, which is what keeps it reachable on a turn led by ANY
//  world — native, dynamic, or none.
//
//  WHY IT IS NOT A DECLARED BROWSING COMMAND. `browsing.mary` would be the
//  obvious home, and it cannot be one: the macUI step grammar locates an
//  element only through `PluginAccessibilityAnchorLocatorSchema`, which
//  requires an exact identifier or title under a pinned window. A page's skip
//  button has neither, and never will. The closed grammar is right; this act
//  belongs to Mary.
//

import Foundation

public struct AffordancePlugin: MaryAdapter {

    public let name = "affordances"
    public let summary = "Act on whatever the screen is currently offering — press the control that accomplishes what the user asked, in any application."

    public init() {}

    public var promptFragment: String? { nil }
    public var abilities: Set<AbilityID> { [] }
    /// NO ALIASES. An alias is how a phrase names an APPLICATION, and this
    /// names none; adding "screen" here would put it in competition with
    /// `looking`, which genuinely answers questions about the screen.
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
