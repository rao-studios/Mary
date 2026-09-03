//
//  ElementIdentity.swift
//  MaryComputerUse
//
//  WHAT: The re-finding key for one element, and the normalization under it.
//  IN:   AXScreenElement | a role + label read live
//  OUT:  ambient records, affordance resolution, the spoken lane
//  PIN:  ONE SPELLING. A focused element, a rostered one and a spoken match
//        must produce the same key or re-finding silently fails, so every
//        caller comes through here — MaryPlugin's AmbientBridge.identity and
//        SpokenReference.normalized are forwarders, not second copies.
//

import Foundation

public enum ElementIdentity {

    /// Lowercase, punctuation to spaces, runs collapsed, trimmed.
    public static func normalized(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(
                of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .replacingOccurrences(
                of: " +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// The re-finding key from the two parts that make it.
    public static func identity(role: String, label: String) -> String {
        "\(role.lowercased())|\(normalized(label))"
    }

    /// The same key, spelled for a snapshot element.
    public static func identity(of element: AXScreenElement) -> String {
        identity(role: element.role, label: element.label)
    }
}
