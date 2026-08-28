import MaryFoundation
import Foundation

/// Turns package-carried Dynamic Plugin declarations into the same value
/// contracts used by Mary's Native Plugins. Compilation is deliberately
/// pure: live machine grants enter through the injected resolver and the
/// resulting availability is frozen into the manifest.
public enum PluginCompiler {
    /// Exact identity of one provider asking Mary to resolve its declared
    /// machine authority. Production currently answers from Mary's live
    /// allowlisted macOS grants; hosts that persist narrower decisions can key
    /// them by this complete value so a changed package never inherits an old
    /// adapter-wide decision.
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

    /// - Parameters:
    ///   - packages: The complete, already-selected active Ability graph.
    ///   - nativeAdapterManifests: Native IDs are reserved. A package cannot
    ///     replace or decorate a compiled Mary adapter by choosing its ID.
    ///   - grantedPermissions: Machine truth, normally supplied by Mary's
    ///     permission center. Values not requested by the package are ignored.
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

        // Settings controls which Native providers execute, never which Native
        // identities exist. The full compiled catalog remains reserved so a
        // Dynamic package cannot claim a disabled Native app and make toggling
        // that app back on invalidate the Ability graph.
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

        // WHICH ABILITIES CLAIM EXPERTISE IN WHICH APPLICATION, read from the
        // channel the schema already provides.
        //
        // THE INCIDENT THIS CLOSES. Scrivener moved from a native plugin to a
        // Dynamic package, and the native plugin had carried
        // `abilities: [.writing]`. The Dynamic profile is built below from the
        // package's own ability id plus its realization owners — all of which
        // are `scrivener` — so the profile that matches
        // `com.literatureandlatte.scrivener3` no longer contained `.writing`.
        // `AmbientEngine.classify` reads exactly that field to decide whether
        // an action turn in this app is `compose` or `operate`, so every
        // dictated sentence in Scrivener classified as `operate`, the Writing
        // Ability's own routing policy admits only `compose`/`revise`/a live
        // selection, and `type_at_cursor` was refused at dispatch with "does
        // not match its Ability-level routing policy". Writing into a
        // manuscript became impossible; Pages and TextEdit were fine, because
        // their native plugins still carry both the bundle id and `.writing`.
        //
        // `writing.mary` already declares Scrivener in `ability.applications`
        // — a discipline naming an application is making the same claim a
        // native plugin makes with `abilities`. It simply was not being read
        // here. Keyed by application id AND by bundle identifier, because the
        // two packages need not agree on the id.
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
            // PERCEPTION ONLY IF THE PROVIDER IS AVAILABLE. Recognition and
            // execution are deliberately separate everywhere else here. The
            // Dynamic claim is only Mary's generic Accessibility perception;
            // no package operation is ever scheduled in the background.
            perception: providerIsAvailable
                ? perception(
                    from: plugin.application.perception,
                    // THE SAME FOUR CHANNELS THE VALIDATOR ADMITS. Written as
                    // one expression rather than four call sites so the two
                    // gates cannot drift apart again — see `perception`.
                    declaresObservationSurface: plugin.proseSurface != nil
                        || plugin.mediaSurface != nil
                        || plugin.corpus != nil
                        || plugin.browserSurface != nil)
                : nil,
            // WHAT THIS APPLICATION CALLS ITS DOCUMENTS, straight from the
            // declaration. The word reaches the window classifier and the
            // spoken register from here — one source, so the word Mary
            // listens for and the word she says back are the same word.
            documentNoun: plugin.proseSurface?.documentNoun.singular)
        // `ApplicationProfile` includes a Native Plugin's display title as a
        // convenience alias. Dynamic display text is not a routing grant;
        // only the portable id and separately validated aliases may match an
        // utterance.
        profile.aliases = routingAliases.union([plugin.application.id])
        return profile
    }

    /// A package projects MARY-OWNED perception only: the generic
    /// Accessibility reader, and — when it declares an observation surface —
    /// Mary's own reader for whatever that surface describes.
    /// `documentOperation` stays nil in both arms, because a
    /// package-supplied operation is the one thing that would put package
    /// code on a background timer against the user's work.
    ///
    /// THE SURFACE IS CHECKED HERE, NOT ONLY IN THE VALIDATOR. The validator
    /// refuses the package at admission; this refuses the CLAIM at
    /// compilation, so a graph that somehow reached this point without a
    /// surface degrades to selection-only rather than being handed eyes with
    /// nothing behind them.
    ///
    /// ⚠️ ALL FOUR SURFACES COUNT, and for a while only one did. The
    /// validator was widened to accept a media surface, then a corpus, then a
    /// browser surface — and this gate was left asking about prose alone. The
    /// two halves disagreeing is silent by construction: the package is
    /// admitted, the workspace claim is quietly downgraded to
    /// `.perceptionOnly`, `observesDocuments` stays false, and the place
    /// reports `hasEyes == false` for an application that plainly has them.
    /// Nothing fails; the application is simply never treated as somewhere
    /// the user is working. Found by the browsing lane's live pass, and it
    /// had been true of the media and corpus lanes since they landed.
    /// Internal rather than private so the gate can be tested DIRECTLY.
    /// It is a pure decision with four inputs and a silent failure mode, and
    /// reaching it through a whole compile would test the compile.
    static func perception(
        from schema: PluginApplicationPerceptionSchema?,
        declaresObservationSurface: Bool
    ) -> ApplicationPerception? {
        guard let schema else { return nil }
        switch schema.kind {
        case .perceptionOnly:
            return ApplicationPerception(
                kind: .perceptionOnly, documentOperation: nil,
                pollSeconds: ApplicationPerception.pollBounds.lowerBound)
        case .workspace:
            guard declaresObservationSurface else {
                return ApplicationPerception(
                    kind: .perceptionOnly, documentOperation: nil,
                    pollSeconds: ApplicationPerception.pollBounds.lowerBound)
            }
            // `readsDocumentCorpus` is read only through `observesDocuments`,
            // whose question is "does Mary have a way to see the work here" —
            // true of a prose surface's text, a player's transport, a corpus
            // on disk and a browser's pages alike. The field kept the name it
            // was born with; the question it answers was always the wider one.
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
    /// introduce multiline prompt structure when deposited into a Totem or
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
