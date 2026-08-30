//
//  AbilityRuntimeSnapshot+Ambient.swift
//  MaryBrain
//
//  WHAT: Frozen registry through the two-member window MaryAmbient needs.
//  IN:   AbilityRuntimeSnapshot
//  OUT:  capability-index install
//  PIN:  MaryAmbient must not name AbilityRuntimeSnapshot.
//
import MaryAmbient
import Foundation

extension AbilityRuntimeSnapshot: AbilityCapabilityIndex {
    public func paradigm(of abilityID: AbilityID) -> AbilityParadigm? {
        records.first { $0.package.ability.id == abilityID }?.package.paradigm
    }
}

public enum AmbientCapabilityBridge {
    /// Points MaryAmbient at the live registry. Called once at configuration;
    /// before it runs, ambient routing reads an empty index rather than block.
    public static func install() {
        AmbientCapabilityIndexProvider.install {
            AbilityLibrary.shared.snapshotEnsuringLoaded()
        }
    }
}
