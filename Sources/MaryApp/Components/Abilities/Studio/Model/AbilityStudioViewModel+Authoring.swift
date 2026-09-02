import MaryBrain
import Foundation

@MainActor
extension AbilityStudioViewModel {
    /// Visual edit through AbilityStudioAuthoringDocument, then canonical JSON into `updateDraft`.
    @discardableResult
    func mutateAuthoringDocument(
        _ transform: (inout AbilityStudioAuthoringDocument) throws -> Void
    ) -> Bool {
        guard let package = draftPackage else {
            status = "The draft JSON does not decode — repair it in Advanced ▸ Schema first."
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
