//
//  AXNodeCategory.swift
//  MaryComputerUse
//
//  WHAT: Coarse role/subrole → stroke family. Total: every role lands, .other included.
//  IN:   AX role string  OUT: WireframeRenderer stroke
//  PIN:  .scripted is never returned by category(role:), and this build has no
//        producer for it at all — the grafting lane it was cut for did not come
//        across. FLAG: dead case, decide to revive or delete deliberately.

import Foundation

public enum AXNodeCategory: Sendable, Equatable {
    case interactive
    case text
    case image
    case container
    case scrollArea
    /// The root of a rendered page — Safari's and Chromium's `AXWebArea`, and the same role
    /// an Electron/CEF app exposes for its renderer view.
    case webArea
    /// A node SYNTHESIZED by the scripting sub-engine (`AXEngine/Scripting/`), never walked
    /// from AX.
    case scripted
    case window
    case other

    /// Classify a node from its role/subrole alone. Subrole wins where it disambiguates (an
    /// `AXCloseButton` subrole on a generic button role is still interactive either way, so
    /// subrole only matters where the bare role is ambiguous.
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
