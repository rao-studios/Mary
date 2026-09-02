//
//  AbilityStudioBindings.swift
//  Mary
//
//  WHAT: Draft binding helper and unused-name search, moved from the old control kit.
//  IN:   Studio panes.
//  OUT:  AbilityStudioViewModel.mutateDraftPackage
//

import MaryBrain
import SwiftUI

/// Returns the first positive suffix whose candidate is not already owned.
/// Add buttons use this instead of array counts because authors may remove,
/// reorder, or import sparsely numbered schema elements.
func abilityStudioFirstUnusedSuffix(
    where isUsed: (Int) -> Bool
) -> Int {
    var suffix = 1
    while isUsed(suffix) { suffix += 1 }
    return suffix
}

func abilityStudioFirstUnusedName<S: Sequence>(
    stem: String,
    separator: String = "-",
    existing: S
) -> String where S.Element == String {
    let owned = Set(existing)
    let suffix = abilityStudioFirstUnusedSuffix {
        owned.contains("\(stem)\(separator)\($0)")
    }
    return "\(stem)\(separator)\(suffix)"
}

@MainActor
func draftBinding<Value>(
    _ value: Value,
    model: AbilityStudioViewModel,
    set: @escaping (inout MaryAbilityPackage, Value) -> Void
) -> Binding<Value> {
    Binding(
        get: { value },
        set: { next in model.mutateDraftPackage { set(&$0, next) } })
}
