import MaryBrain
import Foundation

@MainActor
extension AbilityStudioViewModel {
    /// Runs a visual edit through the reference-safe authoring model, then
    /// returns its canonical package JSON to the existing draft pipeline.
    ///
    /// The active registry supplies graph context for cross-package Skills and
    /// dependencies. The document itself excludes the matching active package,
    /// so an unsaved draft always remains the sole candidate for its package ID.
    @discardableResult
    func mutateAuthoringDocument(
        _ transform: (inout AbilityStudioAuthoringDocument) throws -> Void
    ) -> Bool {
        guard let package = draftPackage else {
            status = "The draft JSON does not decode — fix it in the Schema tab first."
            return false
        }

        var document = AbilityStudioAuthoringDocument(
            package: package,
            contextPackages: snapshot.records.map(\.package))
        do {
            try transform(&document)
            updateDraft(try document.canonicalJSON())
            return true
        } catch {
            status = "Edit not applied — \(error.localizedDescription)"
            return false
        }
    }
}
