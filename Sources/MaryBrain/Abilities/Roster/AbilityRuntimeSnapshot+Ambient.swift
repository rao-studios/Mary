//
//  AbilityRuntimeSnapshot+Ambient.swift
//
//  The frozen registry, seen through the two-member window the ambient layer
//  actually needs.
//
//  MaryAmbient must not name AbilityRuntimeSnapshot — routing an utterance
//  needs one fact from the capability graph, not the graph. This is where the
//  real thing satisfies that window, and where the provider is installed so a
//  caller that hands the engine no index still gets the live one.
//

import MaryAmbient
import Foundation

extension AbilityRuntimeSnapshot: AbilityCapabilityIndex {}

public enum AmbientCapabilityBridge {
    /// Points MaryAmbient at the live registry. Called once at configuration;
    /// before it runs, ambient routing reads an empty index rather than block.
    public static func install() {
        AmbientCapabilityIndexProvider.install {
            AbilityLibrary.shared.snapshotEnsuringLoaded()
        }
    }
}
