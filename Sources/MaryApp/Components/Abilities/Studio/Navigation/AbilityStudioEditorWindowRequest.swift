import MaryBrain

/// Editor handoff: existing id, or a new in-memory canonical draft (no install).
struct AbilityStudioEditorWindowRequest: Codable, Hashable, Sendable {
    let packageID: PackageID
    let initialDraft: MaryAbilityPackage?

    init(packageID: PackageID) {
        self.packageID = packageID
        initialDraft = nil
    }

    init(newPackage: MaryAbilityPackage) {
        packageID = newPackage.package.id
        initialDraft = newPackage
    }
}
