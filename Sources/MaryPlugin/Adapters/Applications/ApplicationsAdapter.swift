//
//  ApplicationsAdapter.swift
//  MaryBrain
//
//  WHAT: Roster slot for the generic app representation. Zero Skills.
//  IN:   MaryAdapterCatalog (bijection with AmbientWorld.allCases)
//  OUT:  ApplicationsWatcher (the actual selection transport)
//  PIN:  Registration only — Settings/catalog does not gate selection.
//

import Foundation

public struct ApplicationsAdapter: MaryAdapter {
    public let name = "applications"
    public let summary = "sees the user's live text selection in whichever app is frontmost; ambient context only, with no executable Skills"
    public let skillBindings: [SkillBinding] = []

    public init() {}
}
