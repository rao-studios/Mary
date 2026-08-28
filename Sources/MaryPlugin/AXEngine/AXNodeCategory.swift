//
//  AXNodeCategory.swift
//  MaryAdapter
//
//  THE AX ENGINE — see AXEngine.swift for the directory's doctrine header.
//
//  The coarse shape a role/subrole maps to — what Clyde's WireframeRenderer
//  actually draws differently (a stroke style per case, not per one of AX's
//  several dozen roles). The table is seeded from
//  `PageElementReader.collectedRoles` (the page lane's own "what counts as
//  interactive" list) plus the structural roles a page-scoped reader never
//  needed: AXScrollArea, AXGroup, AXStaticText, AXImage, AXWindow — and
//  AXWebArea, which a page-scoped reader never needed because it always
//  STARTED there (see `AXEngine/Web/`).
//
//  Pure and total — every role lands somewhere, `.other` included — so this
//  is unit-testable without AX IPC (see AXNodeCategoryTests).
//

import Foundation

public enum AXNodeCategory: Sendable, Equatable {
    case interactive
    case text
    case image
    case container
    case scrollArea
    /// The root of a rendered page — Safari's and Chromium's `AXWebArea`,
    /// and the same role an Electron/CEF app exposes for its renderer view.
    /// A category rather than a container because two other files branch on
    /// it: the builder escalates the whole subtree onto `webAreaBudget`
    /// (a page is an order of magnitude bigger than native chrome), and
    /// Clyde draws it as the page boundary. See `AXEngine/Web/`.
    case webArea
    /// A node SYNTHESIZED by the scripting sub-engine (`AXEngine/Scripting/`),
    /// never walked from AX. `category(role:)` deliberately never returns
    /// this — its role, "BonnieScripted", falls to `.other` like any string
    /// the role table doesn't know, and `ScriptedGraft` sets the category
    /// directly. Synthesis is the only door, so a `.scripted` node can never
    /// be mistaken for something Accessibility actually said.
    case scripted
    case window
    case other

    /// Classify a node from its role/subrole alone. Subrole wins where it
    /// disambiguates (an `AXCloseButton` subrole on a generic button role is
    /// still interactive either way, so subrole only matters where the bare
    /// role is ambiguous — none are, today; the parameter is kept for the
    /// cases AX does use it, e.g. a future search-field subrole).
    public static func category(role: String, subrole: String? = nil) -> AXNodeCategory {
        switch role {
        case "AXWindow", "AXSheet", "AXDrawer":
            return .window
        case "AXWebArea":
            return .webArea
        case "AXScrollArea":
            return .scrollArea
        case "AXImage":
            return .image
        case "AXStaticText", "AXHeading":
            return .text
        case "AXLink", "AXButton", "AXTextField", "AXTextArea", "AXCheckBox",
             "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXDisclosureTriangle",
             "AXComboBox", "AXSlider", "AXTab", "AXMenuItem", "AXMenuBarItem":
            return .interactive
        case "AXGroup", "AXRow", "AXCell", "AXOutline", "AXTable", "AXList",
             "AXToolbar", "AXTabGroup", "AXSplitGroup", "AXLayoutArea":
            return .container
        default:
            return .other
        }
    }
}
