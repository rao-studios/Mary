//
//  ApplicationsAdapter.swift
//  MaryBrain
//
//  A ZERO-RECIPE plugin — the first one. It exists to give the generic app
//  representation a place in the roster, satisfying the pinned bijection
//  between `AmbientWorld.allCases` and
//  `MaryAdapterCatalog.allPluginIDs` (`everyPluginOwnerIsAWorld`,
//  `PluginConfigTests.rosterMatchesIDs`). No Skills means none of the
//  catalog's binding-shaped tests (allowlist, budgets, stage set) have
//  anything to check here; the roster line itself still counts against
//  `PluginCatalogTests.fullPromptBudget`.
//
//  The Settings/catalog representation does NOT gate the shared selection
//  ability. See `ApplicationsWatcher.swift` for that core transport; this file
//  is registration, not behavior.
//

import Foundation

public struct ApplicationsAdapter: MaryAdapter {
    public let name = "applications"
    public let summary = "sees the user's live text selection in whichever app is frontmost; ambient context only, with no executable Skills"
    public let skillBindings: [SkillBinding] = []

    public init() {}
}
