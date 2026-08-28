import MaryBrain
import Foundation

struct AbilityStudioDependencyPresentation: Hashable, Identifiable {
    let packageID: PackageID
    let title: String
    let minimumVersion: SemanticVersion
    let isOptional: Bool
    let installedVersion: SemanticVersion?

    var id: PackageID { packageID }
    var isSatisfied: Bool {
        guard let installedVersion else { return isOptional }
        return installedVersion >= minimumVersion
    }

    init(
        dependency: AbilityPackageDependency,
        installedPackage: MaryAbilityPackage?
    ) {
        packageID = dependency.packageID
        title = installedPackage?.ability.title
            ?? dependency.packageID.rawValue.replacingOccurrences(
                of: "-", with: " ").capitalized
        minimumVersion = dependency.minimumVersion
        isOptional = dependency.optional
        installedVersion = installedPackage?.package.version
    }
}

struct AbilityStudioApplicationPresentation: Hashable {
    let providerClass: PluginProviderClass
    let pluginID: String
    let pluginTitle: String
    let carryingPackageID: PackageID
    let carryingPackageVersion: SemanticVersion
    let applicationID: String
    let applicationTitle: String
    let aliases: [String]
    let bundleIdentifiers: [String]
    let bundleNames: [String]
    let supportedReleases: [PluginApplicationReleaseSchema]
    let applicationResolution: PluginApplicationResolution
    let activation: PluginApplicationActivation
    let adapters: [PluginAdapterSchema]
    let requiredPermissions: [PermissionKind]
    let declaredRealizedSkillCount: Int
    let activeRealizedSkillCount: Int

    @MainActor
    init?(
        package: MaryAbilityPackage,
        activeRealizedSkillCount: Int,
        applicationLocator: PluginApplicationLocator = .live
    ) {
        guard let plugin = package.plugin else { return nil }
        providerClass = .package
        pluginID = plugin.id
        pluginTitle = plugin.title
        carryingPackageID = package.package.id
        carryingPackageVersion = package.package.version
        applicationID = plugin.application.id
        applicationTitle = plugin.application.title
        aliases = plugin.application.aliases
        bundleIdentifiers = plugin.application.bundleIdentifiers
        bundleNames = plugin.application.bundleNames
        supportedReleases = plugin.application.supportedReleases
        applicationResolution = applicationLocator.resolve(plugin.application)
        activation = plugin.application.activation
        adapters = plugin.adapters
        requiredPermissions = plugin.adapters
            .flatMap(\.permissions)
            .reduce(into: [PermissionKind]()) { unique, permission in
                if !unique.contains(permission) { unique.append(permission) }
            }
        declaredRealizedSkillCount = Set(plugin.realizations.map(\.skillID)).count
        self.activeRealizedSkillCount = activeRealizedSkillCount
    }
}

struct AbilityStudioProviderRealizationPresentation: Hashable, Identifiable {
    let provider: AdapterProviderProvenance
    let realizedSkillCount: Int
    let activeSkillCount: Int
    let isAvailable: Bool
    let unavailableReason: String?
    let bundleIdentifiers: [String]
    let bundleNames: [String]
    let applicationResolution: PluginApplicationResolution?
    let requiredPermissions: [PermissionKind]

    var id: String {
        [
            provider.pluginClass.rawValue,
            provider.pluginID,
            provider.originPackageID?.rawValue ?? "native",
            provider.applicationID ?? "application-neutral",
        ].joined(separator: "|")
    }
}
