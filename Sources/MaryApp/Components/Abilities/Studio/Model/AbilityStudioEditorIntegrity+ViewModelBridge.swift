//
//  AbilityStudioEditorIntegrity+ViewModelBridge.swift
//

import MaryBrain
import Foundation

@MainActor
extension AbilityStudioViewModel {
    /// Applies a whole-package visual cascade to a copy, validates it against
    /// the active graph, then replaces the canonical draft only on success.
    @discardableResult
    func mutateValidatedEditorPackage(
        _ transform: (inout MaryAbilityPackage) throws -> Void
    ) -> Bool {
        guard var candidate = draftPackage else {
            status = "The draft JSON does not decode — repair it in Advanced ▸ Schema first."
            return false
        }
        do {
            candidate.integrity = nil
            try transform(&candidate)
            let document = AbilityStudioAuthoringDocument(
                package: candidate,
                contextPackages: snapshot.records.map(\.package))
            let errors = document.validation.issues.filter {
                $0.severity == .error
            }
            guard errors.isEmpty else {
                throw AbilityStudioAuthoringError.invalidMutation(errors)
            }
            updateDraft(try document.canonicalJSON())
            return true
        } catch {
            status = "Edit not applied — \(error.localizedDescription)"
            return false
        }
    }
}
