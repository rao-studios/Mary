//
//  PluginValidator+Validate.swift
//

import Foundation

extension PluginValidator {

    public static func validate(
        _ plugin: PluginSchema,
        in package: MaryAbilityPackage
    ) -> AbilityPackageValidation {
        var issues: [SchemaIssue] = []
        func error(_ code: String, _ path: String, _ message: String) {
            issues.append(.init(severity: .error, code: code, path: path, message: message))
        }
        func text(_ value: String, path: String, noun: String) {
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                error("missing-plugin-\(noun)", path, "Every Plugin \(noun) must contain text.")
            }
        }

        let root = "plugin"
        guard plugin.id == package.package.id.rawValue else {
            error(
                "plugin-package-mismatch",
                "\(root).id",
                "A Plugin id must match the Ability package that carries it.")
            return .init(issues: issues)
        }
        if !SchemaIdentifierValidation.isValid(plugin.id) {
            error("invalid-plugin-id", "\(root).id", "Use a portable lower-case identifier.")
        }
        if !SemanticVersion.isValid(plugin.version.rawValue) {
            error("invalid-plugin-version", "\(root).version", "Use semantic versioning such as 1.0.0.")
        }
        text(plugin.title, path: "\(root).title", noun: "title")
        if plugin.title.utf8.count > maximumTitleBytes {
            error(
                "plugin-title-too-long",
                "\(root).title",
                "A Plugin title may contain at most \(maximumTitleBytes) UTF-8 bytes.")
        }

        let application = plugin.application
        if application.id != plugin.id {
            error(
                "plugin-application-plugin-mismatch",
                "\(root).application.id",
                "The flagship application identity must match its Plugin id.")
        }
        if !SchemaIdentifierValidation.isValid(application.id) {
            error("invalid-plugin-application-id", "\(root).application.id", "Use a portable lower-case identifier.")
        }
        text(application.title, path: "\(root).application.title", noun: "application-title")
        if application.title.utf8.count > maximumTitleBytes {
            error(
                "plugin-application-title-too-long",
                "\(root).application.title",
                "A Plugin application title may contain at most \(maximumTitleBytes) UTF-8 bytes.")
        }
        if application.bundleIdentifiers.isEmpty {
            error(
                "missing-plugin-bundle-identifier",
                "\(root).application.bundleIdentifiers",
                "A Plugin must own at least one exact application bundle identifier.")
        }
        if application.bundleIdentifiers.count > 8 {
            error(
                "too-many-plugin-bundle-identifiers",
                "\(root).application.bundleIdentifiers",
                "A Plugin may declare at most eight bundle identifiers.")
        }
        for duplicate in duplicates(application.bundleIdentifiers.map { $0.lowercased() }) {
            error(
                "duplicate-plugin-bundle-identifier",
                "\(root).application.bundleIdentifiers",
                "Bundle identifier \(duplicate) appears more than once.")
        }

        for (index, identifier) in application.bundleIdentifiers.enumerated()
        where !bundleIdentifierIsValid(identifier) {
            error(
                "invalid-plugin-bundle-identifier",
                "\(root).application.bundleIdentifiers[\(index)]",
                "Use an exact reverse-DNS application bundle identifier.")
        }
        if let prefix = application.bundleIdentifierPrefix {
            let path = "\(root).application.bundleIdentifierPrefix"
            if !bundleIdentifierIsValid(prefix) {
                error(
                    "invalid-plugin-bundle-identifier-prefix",
                    path,
                    "Use a reverse-DNS application bundle family prefix.")
            } else {
                for (index, identifier) in application.bundleIdentifiers.enumerated()
                where bundleIdentifierIsValid(identifier)
                    && !PluginApplicationSchema.bundleIdentifier(
                        identifier,
                        isInFamily: prefix) {
                    error(
                        "unrelated-plugin-bundle-identifier-prefix",
                        path,
                        "Bundle family \(prefix) must own every exact application identity; \(identifier) at bundleIdentifiers[\(index)] is outside that family.")
                }
            }
        }
        if application.bundleNames.count > maximumBundleNames {
            error(
                "too-many-plugin-bundle-names",
                "\(root).application.bundleNames",
                "A Plugin may declare at most \(maximumBundleNames) application bundle names.")
        }
        for duplicate in duplicates(application.bundleNames.map { $0.lowercased() }) {
            error(
                "duplicate-plugin-bundle-name",
                "\(root).application.bundleNames",
                "Application bundle name \(duplicate) appears more than once.")
        }
        for (index, name) in application.bundleNames.enumerated() {
            let path = "\(root).application.bundleNames[\(index)]"
            if name.utf8.count > maximumBundleNameBytes {
                error(
                    "plugin-bundle-name-too-long",
                    path,
                    "An application bundle name may contain at most \(maximumBundleNameBytes) UTF-8 bytes.")
                continue
            }
            if !bundleNameIsValid(name) {
                error(
                    "invalid-plugin-bundle-name",
                    path,
                    "Use a path-free application bundle name ending in .app, such as MyEditor.app.")
            }
        }
        if application.supportedReleases.count > maximumSupportedReleases {
            error(
                "too-many-plugin-supported-releases",
                "\(root).application.supportedReleases",
                "A Plugin application may conform at most \(maximumSupportedReleases) exact release tuples.")
        }
        for _ in duplicates(application.supportedReleases) {
            error(
                "duplicate-plugin-supported-release",
                "\(root).application.supportedReleases",
                "Each supported application release tuple must be unique.")
        }
        for (index, release) in application.supportedReleases.enumerated() {
            for (field, value) in [
                ("shortVersion", release.shortVersion),
                ("bundleVersion", release.bundleVersion),
            ] where !applicationReleaseVersionIsValid(value) {
                error(
                    "invalid-plugin-application-release-version",
                    "\(root).application.supportedReleases[\(index)].\(field)",
                    "Application release versions must be nonempty visible ASCII of at most \(maximumApplicationReleaseVersionBytes) UTF-8 bytes.")
            }
        }
        validateAliases(application.aliases, path: "\(root).application.aliases", error: error)
        if application.targetClasses.count > maximumTargetClasses {
            error(
                "too-many-plugin-target-classes",
                "\(root).application.targetClasses",
                "A Plugin application may declare at most \(maximumTargetClasses) target classes.")
        }
        for (index, targetClass) in application.targetClasses.enumerated()
        where !SchemaIdentifierValidation.isValid(targetClass) {
            error(
                "invalid-plugin-target-class",
                "\(root).application.targetClasses[\(index)]",
                "Plugin target classes use portable lower-case identifiers.")
        }
        for duplicate in duplicates(application.targetClasses) {
            error(
                "duplicate-plugin-target-class",
                "\(root).application.targetClasses",
                "Target class \(duplicate) appears more than once.")
        }
        validateInsets(application.contentInsets, path: "\(root).application.contentInsets", error: error)
        // EYES ARE TWO HALVES, AND THIS IS WHERE THEY ARE CHECKED TOGETHER.
        // A workspace claim says "point the document channel at me", and the
        // only document channel a package may be given is one of Mary's own
        // observation adapters. Without a declaration behind it the claim
        // would be a workspace class with nothing there: a perception card
        // asserting live knowledge of a document, and a passage gate opening
        // onto a reader that was never pointed anywhere.
        //
        // EITHER CHANNEL SATISFIES IT, and the plural is the point: a prose
        // surface is one observation adapter Mary ships, a media surface is
        // another, and a player that declares where its transport lives has
        // been pointed at just as precisely as an editor that declares where
        // its text lives. Naming only the first would have made a media
        // package choose between claiming a perception it could not back and
        // declining eyes it had genuinely earned.
        //
        // A CORPUS IS THE THIRD CHANNEL, and it observes a different thing:
        // the prose and media surfaces watch what is ON SCREEN, a corpus reads
        // the project the screen is showing part of. An application whose work
        // lives in files it edits over days is genuinely observed by the third
        // — refusing it eyes because it publishes no live text would deny a
        // workspace claim that is fully earned.
        //
        // A BROWSER SURFACE IS THE FOURTH, and it observes what the other
        // three cannot: a set of pages, one of which is showing. A browser
        // publishes no document and no transport, so under the first three
        // rules it could see everything a person does all day and claim no
        // eyes for any of it.
        if application.perception?.kind == .workspace,
           plugin.proseSurface == nil, plugin.mediaSurface == nil,
           plugin.corpus == nil, plugin.browserSurface == nil {
            error(
                "unsupported-workspace-perception",
                "\(root).application.perception.kind",
                "A workspace perception claim requires a proseSurface, a mediaSurface, a corpus or a browserSurface: one of Mary's observation adapters is the only channel a Plugin may be observed through.")
        }

        if plugin.adapters.isEmpty {
            error(
                "missing-plugin-adapter",
                "\(root).adapters",
                "A Plugin must declare at least one adapter.")
        }
        for duplicate in duplicates(plugin.adapters.map { $0.id.rawValue }) {
            error(
                "duplicate-plugin-adapter-id",
                "\(root).adapters",
                "Adapter \(duplicate) appears more than once in one Plugin.")
        }
        if plugin.adapters.count > 1 {
            error(
                "too-many-plugin-adapters",
                "\(root).adapters",
                "A data-only Plugin has one macUI adapter interpreted by Mary.")
        }
        for (adapterIndex, adapter) in plugin.adapters.enumerated() {
            let adapterPath = plugin.adapters.count == 1
                ? "\(root).adapter"
                : "\(root).adapters[\(adapterIndex)]"
            validate(
                adapter,
                pluginID: plugin.id,
                path: adapterPath,
                error: error,
                text: { value, path, noun in text(value, path: path, noun: noun) })
        }
        if plugin.operations.isEmpty {
            error("missing-plugin-operation", "\(root).operations", "A Plugin must teach at least one operation.")
        }
        if plugin.operations.count > maximumOperations {
            error(
                "too-many-plugin-operations",
                "\(root).operations",
                "A Plugin may declare at most \(maximumOperations) operations.")
        }
        for duplicate in duplicates(plugin.operations.map(\.operation)) {
            error(
                "duplicate-plugin-operation",
                "\(root).operations",
                "Plugin operation \(duplicate) appears more than once.")
        }
        let totalSteps = plugin.operations.reduce(0) {
            $0 + $1.steps.count + $1.cleanupSteps.count
        }
        if totalSteps > maximumTotalSteps {
            error(
                "too-many-plugin-recipe-steps",
                root,
                "One Plugin may contain at most \(maximumTotalSteps) recipe steps.")
        }
        for (operationIndex, operation) in plugin.operations.prefix(maximumOperations).enumerated() {
            let operationPath = "\(root).operations[\(operationIndex)]"
            guard plugin.adapter(for: operation) != nil else {
                error(
                    "unresolved-plugin-operation-adapter",
                    "\(operationPath).adapterID",
                    "Plugin operation \(operation.operation) must name exactly one of its plugin's declared adapters.")
                continue
            }
            validate(
                operation,
                path: operationPath,
                error: error,
                text: text)
        }
        if plugin.realizations.isEmpty {
            error(
                "missing-plugin-realization",
                "\(root).realizations",
                "A Plugin must map at least one Ability Skill to an operation.")
        }
        if plugin.realizations.count > maximumRealizations {
            error(
                "too-many-plugin-realizations",
                "\(root).realizations",
                "A Plugin may declare at most \(maximumRealizations) Skill realizations.")
        }
        for duplicate in duplicates(plugin.realizations.map {
            "\($0.skillID.rawValue)/\($0.operation)"
        }) {
            error(
                "duplicate-plugin-realization",
                "\(root).realizations",
                "Skill realization \(duplicate) appears more than once.")
        }
        let realizationsByOperation = Dictionary(
            grouping: plugin.realizations,
            by: \.operation)
        for operation in plugin.operations.prefix(maximumOperations) {
            switch realizationsByOperation[operation.operation, default: []].count {
            case 1:
                break
            case 0:
                error(
                    "unrealized-plugin-operation",
                    "\(root).operations",
                    "Plugin operation \(operation.operation) must realize exactly one semantic Skill.")
            default:
                error(
                    "ambiguous-plugin-operation-owner",
                    "\(root).realizations",
                    "Plugin operation \(operation.operation) cannot realize more than one semantic Skill because routing, policy, receipts, and provenance require one owner.")
            }
        }
        let operationNames = Set(plugin.operations.map(\.operation))
        for (index, realization) in plugin.realizations.prefix(maximumRealizations).enumerated() {
            let path = "\(root).realizations[\(index)]"
            if !SchemaIdentifierValidation.isValid(realization.skillID.rawValue) {
                error("invalid-plugin-realization-skill", "\(path).skillID", "A realization must name a portable Skill id.")
            }
            if !operationNames.contains(realization.operation) {
                error(
                    "missing-plugin-realization-operation",
                    "\(path).operation",
                    "Realization operation \(realization.operation) is not declared by this Plugin.")
            }
            if realization.preference < -10_000 || realization.preference > 10_000 {
                error(
                    "invalid-plugin-realization-preference",
                    "\(path).preference",
                    "Realization preference must be between -10000 and 10000.")
            }
            if realization.targetClasses.count > maximumTargetClasses {
                error(
                    "too-many-plugin-realization-targets",
                    "\(path).targetClasses",
                    "A Realization may declare at most \(maximumTargetClasses) target classes.")
            }
            for duplicate in duplicates(realization.targetClasses) {
                error(
                    "duplicate-plugin-realization-target",
                    "\(path).targetClasses",
                    "Target class \(duplicate) appears more than once.")
            }
            for (targetIndex, target) in realization.targetClasses.enumerated()
            where !SchemaIdentifierValidation.isValid(target) {
                error(
                    "invalid-plugin-realization-target",
                    "\(path).targetClasses[\(targetIndex)]",
                    "Realization target classes use portable lower-case identifiers.")
            }
        }
        if let proseSurface = plugin.proseSurface {
            validateProseSurface(proseSurface, root: root, error: error)
        }
        if let browserSurface = plugin.browserSurface {
            validateBrowserSurface(browserSurface, root: root, error: error)
        }
        if let corpus = plugin.corpus {
            validateCorpus(corpus, root: root, error: error)
        }
        return .init(issues: issues)
    }

}
