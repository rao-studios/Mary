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

    /// Every installed Ability whose paradigm is `.discipline`. ORDERED BY
    /// PACKAGE ID so the axis is stable across launches — arbitration reads
    /// "first" off this, and a set's iteration order would make the lead
    /// wobble between runs for no reason the user could see.
    public var disciplines: [AbilityID] {
        records
            .filter { $0.package.paradigm == .discipline }
            .map(\.package.ability.id)
            .sorted { $0.rawValue < $1.rawValue }
    }

    /// THE DISCIPLINE THE WORDS NAME. Scores the utterance against each
    /// discipline Ability's own authored corpus and takes the leader, provided
    /// it clears the floor and beats the runner-up by the margin.
    ///
    /// The margin IS the old rule that cues from both sides cancel: a sentence
    /// that names two crafts equally is contested, and a contested turn defers
    /// to window truth rather than picking. What changed is that the crafts are
    /// no longer two, and the cues are no longer fifty hand-written words.
    public func discipline(in utterance: String) -> WorkspaceFocus? {
        let installed = Set(disciplines)
        guard !installed.isEmpty else { return nil }
        let ranked = abilityAffinities(in: utterance)
            .filter { installed.contains($0.key) }
            .sorted { $0.value > $1.value }
        guard let best = ranked.first,
              best.value >= SemanticAbilityRequestIndex.defaultPositiveThreshold
        else { return nil }
        if let runnerUp = ranked.dropFirst().first,
           best.value - runnerUp.value < SemanticIntentIndex.margin {
            return nil
        }
        return WorkspaceFocus(best.key)
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
