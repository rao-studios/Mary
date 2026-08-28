import MaryBrain

/// The typed handoff into the standalone Ability Editor. Existing packages
/// carry only their stable id. A newly scaffolded package carries the actual
/// canonical Mary schema as its initial in-memory draft; there is no second
/// editor document format and no installation side effect in this request.
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
