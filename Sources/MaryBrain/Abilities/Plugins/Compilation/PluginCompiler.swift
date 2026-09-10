//
//  PluginCompiler.swift
//  MaryBrain
//
//  WHAT: Compile Dynamic Plugin declarations into Native-shaped contracts.
//  IN:   package PluginSchema + injected grant resolver
//  OUT:  frozen PluginCompilation / availability
//  PIN:  Pure; live grants enter only through the resolver.
//
import MaryFoundation
import Foundation

/// Turns package-carried Dynamic Plugin declarations into the same value contracts used by Mary's Native Plugins.
public enum PluginCompiler {
    /// Exact identity of one provider asking Mary to resolve its declared machine authority.
    public struct PermissionRequest: Hashable, Sendable {
        public var adapterID: AdapterID
        public var applicationID: String
        public var bundleIdentifiers: Set<String>
        public var originPackageID: PackageID
        public var originPackageVersion: SemanticVersion
        public var originPackageDigest: String
        public var requestedPermissions: Set<PermissionKind>
        /// Where the carrying package was discovered.
        public var originSource: AbilityPackageSource?

        public init(
            adapterID: AdapterID,
            applicationID: String,
            bundleIdentifiers: Set<String>,
            originPackageID: PackageID,
            originPackageVersion: SemanticVersion,
            originPackageDigest: String,
            requestedPermissions: Set<PermissionKind>,
            originSource: AbilityPackageSource? = nil
        ) {
            self.adapterID = adapterID
            self.applicationID = applicationID
            self.bundleIdentifiers = bundleIdentifiers
            self.originPackageID = originPackageID
            self.originPackageVersion = originPackageVersion
            self.originPackageDigest = originPackageDigest
            self.requestedPermissions = requestedPermissions
            self.originSource = originSource
        }
    }

    public typealias GrantedPermissionResolver = @Sendable (PermissionRequest) -> Set<PermissionKind>

    /// - Parameters: - packages: The complete, already-selected active Ability graph. - nativeAdapterManifests: Native IDs are reserved.
    public static func compile(
        packages: [MaryAbilityPackage],
        nativeAdapterManifests: [InstalledAdapterManifest],
        nativeApplicationProfiles: [ApplicationProfile] = [],
        reservedNativeAdapterManifests: [InstalledAdapterManifest]? = nil,
        reservedNativeApplicationProfiles: [ApplicationProfile]? = nil,
        packageSources: [PackageID: AbilityPackageSource] = [:],
        grantedPermissions: GrantedPermissionResolver
    ) -> PluginCompilation {
        let graphIssues = PluginGraphValidator.validate(packages).issues
        guard !graphIssues.contains(where: { $0.severity == .error }) else {
            return PluginCompilation(issues: graphIssues)
        }

        // Settings controls which Native providers execute, never which Native identities exist.
        let reservedManifests = reservedNativeAdapterManifests ?? nativeAdapterManifests
        let reservedProfiles = reservedNativeApplicationProfiles ?? nativeApplicationProfiles
        let nativeAdapterIDs = Set(reservedManifests.map(\.adapterID))
        let nativeApplicationIDs = Set(reservedProfiles.map { $0.id.lowercased() })
        let nativeBundleIdentifiers = Set(reservedProfiles.flatMap {
            $0.applicationIdentifiers.map { $0.lowercased() }
        })
        let nativeApplicationAliases = Set(reservedProfiles.flatMap { profile in
            profile.aliases.compactMap {
                ApplicationProfile.routingIdentity(for: $0)
            }
        })
        let reservedOperationNames = Set(
            reservedManifests.flatMap { $0.operations.map(\.operation) })
            .union(RuntimePrimitiveOperations.names)
        let capabilitySchemas = Dictionary(
            packages.flatMap(\.capabilities).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        let skillOwners = Dictionary(
            packages.flatMap { package in
                package.skills.map {
                    ($0.id, (package: package, skill: $0))
                }
            },
            uniquingKeysWith: { first, _ in first })

        // WHICH ABILITIES CLAIM EXPERTISE IN WHICH APPLICATION, read from the channel the schema already provides.
        var affinityAbilities: [String: Set<AbilityID>] = [:]
        for package in packages {
            for affinity in package.applicationAffinities {
                affinityAbilities[affinity.id.lowercased(), default: []]
                    .insert(package.ability.id)
                for bundleIdentifier in affinity.bundleIdentifiers {
                    affinityAbilities[bundleIdentifier.lowercased(), default: []]
                        .insert(package.ability.id)
                }
            }
        }

        let packages = packages.compactMap { package in
            package.plugin.map { (package: package, plugin: $0) }
        }.sorted {
            $0.package.package.id.rawValue < $1.package.package.id.rawValue
        }

        var manifests: [InstalledAdapterManifest] = []
        var realizations: [PluginSkillBindingRealization] = []
        var profiles: [ApplicationProfile] = []
        var issues = graphIssues

        for entry in packages {
            let package = entry.package
            let plugin = entry.plugin

            let shadowedAdapters = plugin.adapters
                .map(\.id)
                .filter(nativeAdapterIDs.contains)
            guard shadowedAdapters.isEmpty else {
                for adapterID in shadowedAdapters {
                    issues.append(.init(
                        severity: .error,
                        code: "adapter-shadows-runtime",
                        path: "\(package.package.id.rawValue).plugin.adapter.id",
                        message: "Dynamic adapter \(adapterID.rawValue) is suppressed because a Native Plugin owns that adapter id."))
                }
                continue
            }

            let applicationID = plugin.application.id.lowercased()
            guard !nativeApplicationIDs.contains(applicationID) else {
                issues.append(.init(
                    severity: .error,
                    code: "application-shadows-runtime",
                    path: "\(package.package.id.rawValue).plugin.application.id",
                    message: "Dynamic application \(plugin.application.id) conflicts with a Native Plugin application identity."))
                continue
            }
            let collidingBundles = Set(plugin.application.bundleIdentifiers.map {
                $0.lowercased()
            }).intersection(nativeBundleIdentifiers)
            guard collidingBundles.isEmpty else {
                issues.append(.init(
                    severity: .error,
                    code: "bundle-shadows-runtime",
                    path: "\(package.package.id.rawValue).plugin.application.bundleIdentifiers",
                    message: "Dynamic bundle identity conflicts with a Native Plugin: \(collidingBundles.sorted().joined(separator: ", "))."))
                continue
            }
            let exactBundles = Set(plugin.application.bundleIdentifiers.map {
                $0.lowercased()
            })
            let familyCollisions = reservedProfiles.filter { profile in
                let nativeExactBundles = Set(profile.applicationIdentifiers.map {
                    $0.lowercased()
                })
                if let packagePrefix = plugin.application.bundleIdentifierPrefix,
                   nativeExactBundles.contains(where: {
                       PluginApplicationSchema.bundleIdentifier(
                           $0,
                           isInFamily: packagePrefix)
                   }) {
                    return true
                }
                if let nativePrefix = profile.applicationBundlePrefix,
                   exactBundles.contains(where: {
                       PluginApplicationSchema.bundleIdentifier(
                           $0,
                           isInFamily: nativePrefix)
                   }) {
                    return true
                }
                if let packagePrefix = plugin.application.bundleIdentifierPrefix,
                   let nativePrefix = profile.applicationBundlePrefix,
                   PluginApplicationSchema.familyPrefix(
                       packagePrefix,
                       overlaps: nativePrefix) {
                    return true
                }
                return false
            }
            guard familyCollisions.isEmpty else {
                issues.append(.init(
                    severity: .error,
                    code: "bundle-family-shadows-runtime",
                    path: "\(package.package.id.rawValue).plugin.application.bundleIdentifierPrefix",
                    message: "Dynamic bundle family identity conflicts with Native Plugin application(s): \(familyCollisions.map(\.id).sorted().joined(separator: ", "))."))
                continue
            }
            let applicationRoutingAliases = Set(plugin.application.aliases)
                .union([plugin.application.id])
                .union(bundleNameRoutingAliases(plugin.application.bundleNames))
            let collidingAliases = Set(
                applicationRoutingAliases.compactMap {
                    ApplicationProfile.routingIdentity(for: $0)
                }
            ).intersection(nativeApplicationAliases)
            guard collidingAliases.isEmpty else {
                issues.append(.init(
                    severity: .error,
                    code: "alias-shadows-runtime",
                    path: "\(package.package.id.rawValue).plugin.application",
                    message: "Dynamic application routing identities conflict with a Native Plugin: \(collidingAliases.sorted().joined(separator: ", "))."))
                continue
            }

            let operationCollisions = plugin.operations
                .map(\.operation)
                .filter(reservedOperationNames.contains)
                .sorted()
            guard operationCollisions.isEmpty else {
                for operation in operationCollisions {
                    issues.append(.init(
                        severity: .error,
                        code: "operation-shadows-runtime",
                        path: "\(package.package.id.rawValue).plugin.operations",
                        message: "Dynamic operation \(operation) conflicts with a Native or Mary-owned runtime operation."))
                }
                continue
            }

            guard let digest = package.integrity?.digest
                ?? (try? AbilityPackageCodec.digest(of: package)) else {
                issues.append(.init(
                    severity: .error,
                    code: "dynamic-provider-digest-failed",
                    path: "\(package.package.id.rawValue).integrity",
                    message: "Dynamic Plugin provenance could not freeze the carrying package digest."))
                continue
            }

            let provenance = AdapterProviderProvenance(
                pluginClass: .package,
                pluginID: plugin.id,
                // Provider identity can reach receipts and tool-result labels;
                // derive it from the validated machine id rather than allowing
                // package-authored prose onto those model-visible surfaces.
                pluginTitle: canonicalDisplayName(plugin.id),
                originPackageID: package.package.id,
                originPackageVersion: package.package.version,
                originPackageDigest: digest,
                applicationID: plugin.application.id)

            let pluginRealizations = plugin.realizations.compactMap { realization
                -> (schema: PluginSkillRealizationSchema,
                    owner: (package: MaryAbilityPackage, skill: SkillSchema))? in
                guard let owner = skillOwners[realization.skillID] else { return nil }
                return (realization, owner)
            }
            let operationsByName = Dictionary(
                plugin.operations.map { ($0.operation, $0) },
                uniquingKeysWith: { first, _ in first })

            for item in pluginRealizations {
                // A realization's binding names the adapter that interprets
                // its operation — with several engines in one plugin, that is
                // a per-operation fact, never a plugin-wide one.
                guard let operation = operationsByName[item.schema.operation],
                      let owningAdapter = plugin.adapter(for: operation)
                else { continue }
                let targets = bindingTargets(
                    realization: item.schema,
                    application: plugin.application)
                realizations.append(PluginSkillBindingRealization(
                    originPackageID: package.package.id,
                    skillID: item.schema.skillID,
                    binding: AdapterBindingReference(
                        adapterID: owningAdapter.id,
                        operation: item.schema.operation,
                        preference: item.schema.preference,
                        targetClasses: targets),
                    provider: provenance))
            }

            var anyAdapterAvailable = false
            var adapterManifestEntries: [InstalledAdapterManifest] = []
            for adapter in plugin.adapters {
                let requested = Set(adapter.permissions)
                let permissionRequest = PermissionRequest(
                    adapterID: adapter.id,
                    applicationID: plugin.application.id,
                    bundleIdentifiers: Set(plugin.application.bundleIdentifiers.map {
                        $0.lowercased()
                    }),
                    originPackageID: package.package.id,
                    originPackageVersion: package.package.version,
                    originPackageDigest: digest,
                    requestedPermissions: requested,
                    originSource: packageSources[package.package.id])
                let granted = requested.intersection(grantedPermissions(permissionRequest))
                let missing = requested.subtracting(granted)
                let unavailableReason: String?
                if missing.isEmpty {
                    unavailableReason = nil
                } else {
                    unavailableReason = "Required permissions are not granted: \(missing.map(\.rawValue).sorted().joined(separator: ", "))."
                }

                let operations = plugin.operations
                    .filter { plugin.adapter(for: $0)?.id == adapter.id }
                    .map { operation in
                        installedBinding(
                            operation: operation,
                            realizations: pluginRealizations.filter {
                                $0.schema.operation == operation.operation
                            },
                            adapter: adapter,
                            application: plugin.application,
                            capabilitySchemas: capabilitySchemas)
                    }.sorted { $0.operation < $1.operation }

                anyAdapterAvailable = anyAdapterAvailable || missing.isEmpty
                adapterManifestEntries.append(InstalledAdapterManifest(
                    adapterID: adapter.id,
                    version: adapter.version,
                    title: sanitizedDisplayText(
                        adapter.title,
                        fallback: adapter.id.rawValue),
                    transport: transport(for: adapter.engine),
                    claimCoverage: .complete,
                    operations: operations,
                    providesInteractions: [],
                    providesPerceptions: [],
                    supportedValueTypes: orderedIDs(operations.flatMap {
                        $0.inputTypes + $0.outputTypes
                    }),
                    grantedPermissions: granted.sorted { $0.rawValue < $1.rawValue },
                    isAvailable: missing.isEmpty,
                    unavailableReason: unavailableReason,
                    provider: provenance))
            }
            manifests.append(contentsOf: adapterManifestEntries)

            profiles.append(applicationProfile(
                package: package,
                plugin: plugin,
                realizations: pluginRealizations,
                providerIsAvailable: anyAdapterAvailable,
                affinityAbilities: affinityAbilities))
        }

        return PluginCompilation(
            adapterManifests: manifests.sorted {
                $0.adapterID.rawValue < $1.adapterID.rawValue
            },
            skillRealizations: realizations.sorted { left, right in
                if left.skillID != right.skillID {
                    return left.skillID.rawValue < right.skillID.rawValue
                }
                if left.binding.preference != right.binding.preference {
                    return left.binding.preference > right.binding.preference
                }
                if left.binding.adapterID != right.binding.adapterID {
                    return left.binding.adapterID.rawValue < right.binding.adapterID.rawValue
                }
                return left.binding.operation < right.binding.operation
            },
            applicationProfiles: profiles.sorted { $0.id < $1.id },
            issues: issues)
    }

    private static func installedBinding(
        operation: PluginOperationSchema,
        realizations: [(
            schema: PluginSkillRealizationSchema,
            owner: (package: MaryAbilityPackage, skill: SkillSchema)
        )],
        adapter: PluginAdapterSchema,
        application: PluginApplicationSchema,
        capabilitySchemas: [CapabilityID: CapabilitySchema]
    ) -> InstalledAdapterBinding {
        let skills = realizations.map { $0.owner.skill }
        let capabilities: [CapabilityID] = orderedIDs(
            skills.flatMap { $0.requirements.capabilities })
        let delegatedFrontmostClaims = capabilities.compactMap {
            capabilitySchemas[$0]
        }.flatMap(\.constraints).filter { constraint in
            // The closed macUI grammar can prove exact application ownership
            // and frontmost status. It cannot yet prove stable document or
            // selection-source identity, so it must not claim those contracts.
            constraint.kind == .requiresFrontmostApplication
        }
        let targets = orderedStrings(
            application.targetClasses
                + realizations.flatMap { $0.schema.targetClasses })

        return InstalledAdapterBinding(
            adapterID: adapter.id,
            operation: operation.operation,
            capabilities: capabilities,
            inputTypes: orderedIDs(skills.flatMap { $0.inputs.map(\.valueType) }),
            outputTypes: orderedIDs(skills.flatMap { $0.outputs.map(\.valueType) }),
            consumesInteractions: orderedIDs(skills.flatMap {
                $0.requirements.interactions
            }),
            observesPerceptions: orderedIDs(skills.flatMap {
                $0.requirements.perceptions
            }),
            targetClasses: targets,
            enforcedConstraints: Array(Set(delegatedFrontmostClaims)).sorted {
                if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
                return $0.value < $1.value
            })
    }

    private static func bindingTargets(
        realization: PluginSkillRealizationSchema,
        application: PluginApplicationSchema
    ) -> [String] {
        orderedStrings(
            realization.targetClasses.isEmpty
                ? application.targetClasses
                : realization.targetClasses)
    }

    private static func applicationProfile(
        package: MaryAbilityPackage,
        plugin: PluginSchema,
        realizations: [(
            schema: PluginSkillRealizationSchema,
            owner: (package: MaryAbilityPackage, skill: SkillSchema)
        )],
        providerIsAvailable: Bool,
        affinityAbilities: [String: Set<AbilityID>]
    ) -> ApplicationProfile {
        let abilities = Set(
            [package.ability.id] + realizations.map { $0.owner.package.ability.id })
            .union(affinityAbilities[plugin.application.id.lowercased()] ?? [])
            .union(plugin.application.bundleIdentifiers.flatMap {
                affinityAbilities[$0.lowercased()] ?? []
            })
        let bundleNames = Set(plugin.application.bundleNames.map {
            sanitizedDisplayText($0, fallback: plugin.application.id)
        })
        let routingAliases = Set(plugin.application.aliases)
            .union(bundleNameRoutingAliases(plugin.application.bundleNames))
        let skills = Dictionary(
            realizations.map { item in
                let name = item.owner.skill.invocationName
                    ?? item.owner.skill.id.rawValue
                return (name, ApplicationProfile.Skill(
                    name: name,
                    // Dynamic package prose never becomes application guidance.
                    description: providerIsAvailable
                        ? "Available through Mary's bounded local application operator."
                        : "Known through an Ability-provided Dynamic Plugin; its local operator is not currently available."))
            },
            uniquingKeysWith: { first, _ in first })
            .values.sorted { $0.name < $1.name }

        var profile = ApplicationProfile(
            id: plugin.application.id,
            // Application knowledge is retrievable model context. Keep its
            // title Mary-derived; the authored title remains inspector-only.
            title: canonicalDisplayName(plugin.application.id),
            summary: providerIsAvailable
                ? "An application Mary can operate through an Ability-provided Dynamic Plugin."
                : "An application Mary recognizes through an Ability-provided Dynamic Plugin whose local operator is not currently available.",
            abilities: abilities,
            aliases: routingAliases,
            applicationIdentifiers: Set(plugin.application.bundleIdentifiers),
            applicationBundlePrefix: plugin.application.bundleIdentifierPrefix,
            applicationBundleNames: bundleNames,
            targetClasses: Set(plugin.application.targetClasses),
            skills: skills,
            guidance: nil,
            // PERCEPTION ONLY IF THE PROVIDER IS AVAILABLE. Recognition and execution are deliberately separate everywhere else here.
            perception: providerIsAvailable
                ? perception(from: plugin.application.perception,
                             proseSurface: plugin.proseSurface,
                             codeSurface: plugin.codeSurface,
                             mediaSurface: plugin.mediaSurface,
                             corpus: plugin.corpus,
                             webSurface: plugin.webSurface)
                : nil,
            // WHAT THIS APPLICATION CALLS ITS DOCUMENTS, straight from the declaration.
            documentNoun: plugin.proseSurface?.documentNoun.singular)
        // `ApplicationProfile` includes a Native Plugin's display title as a convenience alias.
        profile.aliases = routingAliases.union([plugin.application.id])
        return profile
    }

    /// A package projects MARY-OWNED perception only: the generic Accessibility reader, and
    /// The read-only shell read a browser package is polled through — title,
    /// site, tab and window counts, never an address. The web-surface adapter
    /// binds an operation of this name; the two must agree by spelling.
    static let browserDocumentOperation = "page_context"

    private static func perception(
        from schema: PluginApplicationPerceptionSchema?,
        proseSurface: PluginProseSurfaceSchema?,
        codeSurface: PluginCodeSurfaceSchema?,
        mediaSurface: PluginMediaSurfaceSchema?,
        corpus: PluginCorpusSchema?,
        webSurface: PluginWebSurfaceSchema? = nil
    ) -> ApplicationPerception? {
        guard let schema else { return nil }
        switch schema.kind {
        case .perceptionOnly:
            return ApplicationPerception(
                kind: .perceptionOnly, documentOperation: nil,
                pollSeconds: ApplicationPerception.pollBounds.lowerBound)
        case .workspace:
            // A BROWSER IS A WORKSPACE. This guard admitted prose, code, media
            // and corpus surfaces and did not know the web surface existed, so
            // every browser package compiled `.perceptionOnly`: no eyes, no
            // discipline, never able to lead — and a page question asked from
            // an editor, naming the browser, read nothing. MEASURED as
            // "you're looking at whatever webpage is open in your Chrome
            // window" answered from a brief that said the page was unread.
            // The document channel is the shell read, on the poll's cadence.
            if webSurface != nil {
                return ApplicationPerception(
                    kind: .workspace, documentOperation: browserDocumentOperation,
                    pollSeconds: ApplicationPerception.pollBounds.lowerBound)
            }
            guard proseSurface != nil || codeSurface != nil
                    || mediaSurface != nil || corpus != nil else {
                return ApplicationPerception(
                    kind: .perceptionOnly, documentOperation: nil,
                    pollSeconds: ApplicationPerception.pollBounds.lowerBound)
            }
            return ApplicationPerception(
                kind: .workspace, documentOperation: nil,
                pollSeconds: ApplicationPerception.pollBounds.lowerBound,
                readsDocumentCorpus: true)
        }
    }

    private static func bundleNameRoutingAliases(_ bundleNames: [String]) -> Set<String> {
        Set(bundleNames.flatMap { name in
            guard name.hasSuffix(".app") else { return [name] }
            return [name, String(name.dropLast(4))]
        })
    }

    private static func transport(for _: PluginEngine) -> AdapterTransport {
        .accessibility
    }

    /// Display identity is package-authored metadata, but it still must not
    /// introduce multiline prompt structure when deposited into a Thread or
    /// rendered in diagnostics.
    private static func sanitizedDisplayText(
        _ value: String,
        fallback: String
    ) -> String {
        let flattened = value.unicodeScalars.map { scalar -> String in
            CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
        }.joined()
        let normalized = flattened.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let bounded = String(normalized.prefix(96))
        return bounded.isEmpty ? fallback : bounded
    }

    private static func canonicalDisplayName(_ identifier: String) -> String {
        identifier
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { token in
                token.prefix(1).uppercased() + token.dropFirst()
            }
            .joined(separator: " ")
    }

    private static func orderedStrings(_ values: [String]) -> [String] {
        Array(Set(values)).sorted()
    }

    private static func orderedIDs<ID: SchemaIdentifier>(_ values: [ID]) -> [ID] {
        Array(Set(values)).sorted { $0.rawValue < $1.rawValue }
    }
}
