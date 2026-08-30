//
//  AbilityPackageValidator.swift
//  MaryFoundation
//
//  WHAT: Admission for one `.mary` — identity → skills → schemas → paradigm → plugin.
//  IN:   MaryAbilityPackage.
//  OUT:  PackageIssueSink; AbilityPackageValidator+Graph for the installed set.
//  PIN:  Siblings: +Skills, +Schemas, +Paradigm. PluginValidator admits the Plugin.
//

import Foundation

public enum AbilityPackageValidator {
    public static func validate(_ package: MaryAbilityPackage) -> AbilityPackageValidation {
        let sink = PackageIssueSink()
        validateIdentity(package, sink)
        validateSkills(package, sink)
        validateDeclaredSchemas(package, sink)
        validateSchemaReferences(package, sink)
        validateRequirementsAndFixtures(package, sink)
        validateParadigm(package, sink)
        validateApplicationsAndPlugin(package, sink)
        return AbilityPackageValidation(issues: sink.issues)
    }

    /// Identity, version, presentation, routing terms, dependency edges.
    static func validateIdentity(
        _ package: MaryAbilityPackage,
        _ sink: PackageIssueSink
    ) {
        if package.format != MaryAbilityPackage.format {
            sink.error("unsupported-format", "format", "Expected \(MaryAbilityPackage.format).")
        }
        if package.formatVersion != MaryAbilityPackage.currentFormatVersion {
            sink.error("unsupported-format-version", "formatVersion", "Expected format version \(MaryAbilityPackage.currentFormatVersion).")
        }
        sink.checkID(package.package.id.rawValue, "package.id")
        sink.checkID(package.ability.id.rawValue, "ability.id")
        if package.package.id.rawValue != package.ability.id.rawValue {
            sink.error("package-ability-mismatch", "ability.id", "An ability-level package id must match its exported ability id.")
        }
        if package.package.version != package.ability.version {
            sink.error("version-mismatch", "ability.version", "The package and exported ability must have the same version.")
        }
        sink.checkText(package.package.publisher, "package.publisher", "publisher")
        sink.checkText(package.package.summary, "package.summary", "package-summary")
        sink.checkText(package.ability.title, "ability.title", "ability-title")
        sink.checkText(package.ability.summary, "ability.summary", "ability-summary")
        if !semanticVersionIsValid(package.package.version.rawValue) {
            sink.error("invalid-version", "package.version", "Use semantic versioning such as 1.0.0 or 1.0.0-beta.1.")
        }
        if let minimum = package.package.minimumMaryVersion,
           !semanticVersionIsValid(minimum.rawValue) {
            sink.error("invalid-version", "package.minimumMaryVersion", "Use semantic versioning such as 1.0.0.")
        }
        if !isHexTint(package.ability.tint) {
            sink.error("invalid-tint", "ability.tint", "Use a six-digit #RRGGBB color.")
        }
        sink.validateSearchTerms(
            package.ability.aliases,
            path: "ability.aliases",
            noun: "Ability alias")
        sink.validateSearchTerms(
            package.ability.triggers.tokens,
            path: "ability.triggers.tokens",
            noun: "trigger token",
            maximumWordsPerTerm: 1)
        sink.validateSearchTerms(
            package.ability.triggers.phrases,
            path: "ability.triggers.phrases",
            noun: "trigger phrase")
        sink.validateSearchTerms(
            package.ability.triggers.negativeTokens,
            path: "ability.triggers.negativeTokens",
            noun: "negative trigger")
        if package.ability.triggers.intentAliases.count > 64 {
            sink.error(
                "too-many-intent-aliases",
                "ability.triggers.intentAliases",
                "An Ability may declare at most 64 intent aliases.")
        }
        let inspectedIntentAliases = Array(
            package.ability.triggers.intentAliases.prefix(64))
        duplicates(inspectedIntentAliases).forEach { _ in
            sink.error(
                "duplicate-intent-alias",
                "ability.triggers.intentAliases",
                "An intent alias appears more than once.")
        }
        for (index, alias) in inspectedIntentAliases.enumerated() {
            sink.checkID(alias, "ability.triggers.intentAliases[\(index)]")
        }
        duplicates(package.ability.skills.map(\.rawValue)).forEach {
            sink.error("duplicate-ability-skill", "ability.skills", "Skill id \($0) appears more than once in the Ability schema.")
        }
        duplicates(package.ability.totemProjections.map(\.rawValue)).forEach {
            sink.error("duplicate-ability-projection", "ability.totemProjections", "Projection id \($0) appears more than once in the Ability schema.")
        }
        duplicates(package.ability.operatingPolicy.guardrailCategories.map(\.rawValue)).forEach {
            sink.error(
                "duplicate-ability-guardrail-category",
                "ability.operatingPolicy.guardrailCategories",
                "Guardrail category \($0) appears more than once.")
        }
        duplicates(package.dependencies.map { $0.packageID.rawValue }).forEach {
            sink.error("duplicate-dependency", "dependencies", "Package dependency \($0) appears more than once.")
        }
        for (index, dependency) in package.dependencies.enumerated() {
            sink.checkID(dependency.packageID.rawValue, "dependencies[\(index)].packageID")
            if dependency.packageID == package.package.id {
                sink.error("self-dependency", "dependencies[\(index)]", "An Ability package cannot depend on itself.")
            }
            if !semanticVersionIsValid(dependency.minimumVersion.rawValue) {
                sink.error("invalid-version", "dependencies[\(index)].minimumVersion", "Use semantic versioning such as 1.0.0.")
            }
        }
        sink.validateRouting(package.ability.routing, path: "ability.routing")
    }

    /// Named affinities, then PluginValidator for a carried Plugin.
    static func validateApplicationsAndPlugin(
        _ package: MaryAbilityPackage,
        _ sink: PackageIssueSink
    ) {
        for (index, affinity) in (package.ability.applications ?? []).enumerated() {
            let path = "\(package.package.id).ability.applications[\(index)]"
            sink.checkID(affinity.id, "\(path).id")
            sink.checkText(affinity.title, "\(path).title", "title")
        }
        if let plugin = package.plugin {
            sink.issues.append(contentsOf: PluginValidator.validate(
                plugin,
                in: package).issues)
        }
        if let corpus = package.corpus {
            PluginValidator.validateCorpus(corpus, root: package.package.id.rawValue) {
                sink.error($0, $1, $2)
            }
        }
    }
}
