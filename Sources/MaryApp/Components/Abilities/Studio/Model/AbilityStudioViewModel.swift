import AppKit
import MaryBrain
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AbilityStudioViewModel: ObservableObject {
    @Published private(set) var snapshot: AbilityRuntimeSnapshot = .empty
    @Published var selectedPackageID: PackageID?
    @Published var draft = "" {
        didSet { decodedDraft = nil }
    }
    @Published private(set) var validation = AbilityPackageValidation()
    @Published private(set) var isDirty = false
    @Published private(set) var isLocalDraft = false
    @Published private(set) var hasPendingRegistryUpdate = false
    @Published var status: String?
    @Published private(set) var applicationResolutionEpoch = 0

    /// A rail selection the draft is standing in the way of. The view asks
    /// Save / Discard / Keep editing rather than refusing the click.
    @Published var pendingSelection: PackageID?

    // Selection state. View state only — `rejectUnknownKeys` refuses anything
    // editor-shaped in the package, so none of this may reach the draft JSON.
    @Published var selectedRecipeID: SkillID?
    @Published var selectedSkillID: SkillID?
    @Published var expandedRecipeStepID: String?

    enum PendingSelectionResolution {
        case save
        case discard
        case cancel
    }

    private let library: AbilityLibrary
    private let applicationLocator: PluginApplicationLocator
    private let workspaceNotificationCenter: NotificationCenter
    private var editSession: AbilityPackageEditSession?
    private var pendingSnapshot: AbilityRuntimeSnapshot?
    private var eventsTask: Task<Void, Never>?
    private var applicationObservers: [NSObjectProtocol] = []

    init(
        library: AbilityLibrary = .shared,
        applicationLocator: PluginApplicationLocator = .live,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.library = library
        self.applicationLocator = applicationLocator
        self.workspaceNotificationCenter = workspaceNotificationCenter
    }

    deinit {
        eventsTask?.cancel()
        applicationObservers.forEach { workspaceNotificationCenter.removeObserver($0) }
    }

    func start() {
        guard eventsTask == nil else { return }
        startApplicationObservation()
        let current = library.snapshotEnsuringLoaded()
        if isDirty {
            acceptActivatedSnapshot(current)
        } else {
            snapshot = current
            selectInitialIfNeeded()
            reloadDraft()
        }
        let events = library.events()
        eventsTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                // Don't promote `self` for this infinite stream. Optional borrow lets deinit cancel.
                self?.handleLibraryEvent(event)
            }
        }
    }

    func stop() {
        eventsTask?.cancel()
        eventsTask = nil
        applicationObservers.forEach { workspaceNotificationCenter.removeObserver($0) }
        applicationObservers = []
    }

    private func startApplicationObservation() {
        guard applicationObservers.isEmpty else { return }
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
        ]
        applicationObservers = names.map { name in
            workspaceNotificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.applicationResolutionEpoch &+= 1
                }
            }
        }
    }

    func select(_ id: PackageID?) {
        guard id != selectedPackageID else { return }
        guard !isDirty else {
            status = "Save or revert the current draft before switching packages."
            return
        }
        selectedPackageID = id
        clearSelectionState()
        reloadDraft()
    }

    /// The rail's entry point. A clean draft switches at once; a dirty one asks.
    func requestSelect(_ id: PackageID?) {
        guard id != selectedPackageID else { return }
        guard isDirty else {
            select(id)
            return
        }
        pendingSelection = id
    }

    func resolvePendingSelection(_ resolution: PendingSelectionResolution) {
        let destination = pendingSelection
        pendingSelection = nil
        switch resolution {
        case .cancel:
            return
        case .save:
            save()
            // Save can fail on validation or an external write. Staying put with
            // the reason in `status` beats discarding the work silently.
            guard !isDirty else { return }
            select(destination)
        case .discard:
            revert()
            select(destination)
        }
    }

    private func clearSelectionState() {
        selectedRecipeID = nil
        selectedSkillID = nil
        expandedRecipeStepID = nil
    }

    // MARK: - The draft

    /// The decode of `draft`, kept until `draft` changes. Outer optional is
    /// "not decoded yet"; inner is "decoded, and the JSON does not parse".
    private var decodedDraft: MaryAbilityPackage??

    /// Source of truth is the draft string. Visual editors re-encode through `updateDraft`.
    ///
    /// PIN: decoded once per change, never per read. A shipped package is
    /// ~100 KB of JSON and every render reaches for this several times — the
    /// header's cost readout, each pane's presentation, the resolver, the
    /// catalog, the bench. Decoding per read cost ~330 ms per window-resize
    /// frame on its own.
    var draftPackage: MaryAbilityPackage? {
        if let cached = decodedDraft { return cached }
        let decoded = try? AbilityPackageCodec.decode(Data(draft.utf8), verifyIntegrity: false)
        decodedDraft = decoded
        return decoded
    }

    func mutateDraftPackage(_ transform: (inout MaryAbilityPackage) -> Void) {
        guard var package = draftPackage else {
            status = "The draft JSON does not decode — repair it in Advanced ▸ Schema first."
            return
        }
        transform(&package)
        guard let data = try? AbilityPackageCodec.encoded(package),
              let json = String(data: data, encoding: .utf8) else {
            status = "The edited package could not be re-encoded."
            return
        }
        updateDraft(json)
    }

    /// Take an in-memory lease on a package that has never been installed and
    /// open it as the current draft. One lease, not two: the old flow took one
    /// to mint a window request and another when that window appeared.
    /// Nothing reaches the registry until Save.
    func openNewPackage(_ package: MaryAbilityPackage) -> Bool {
        do {
            let session = try library.beginCreatingPackage(package)
            selectedPackageID = package.package.id
            editSession = session
            draft = session.draftJSON
            validation = library.validate(json: draft)
            isDirty = true
            isLocalDraft = false
            pendingSnapshot = nil
            hasPendingRegistryUpdate = false
            clearSelectionState()
            status = "Unsaved new Ability — Save installs and activates it for the first time."
            return true
        } catch {
            openFailedNewDraft(package, message: error.localizedDescription)
            return false
        }
    }

    private func openFailedNewDraft(
        _ package: MaryAbilityPackage,
        message: String
    ) {
        selectedPackageID = package.package.id
        editSession = nil
        if let data = try? AbilityPackageCodec.encoded(package),
           let json = String(data: data, encoding: .utf8) {
            draft = json
            validation = library.validate(json: json)
        } else {
            draft = ""
            validation = .init()
        }
        isDirty = true
        isLocalDraft = false
        status = message
    }

    func updateDraft(_ value: String) {
        draft = value
        validation = library.validate(json: value)
        isDirty = true
        status = validation.isValid ? "Valid — Save activates it for the next turn." : nil
    }

    func validateDraft() {
        validation = library.validate(json: draft)
        status = validation.isValid
            ? "Schema and active package graph are valid."
            : validation.issues.first?.message ?? "The package is invalid."
    }

    func reload() {
        guard !isDirty else {
            status = "Reload paused: save or revert the current draft first."
            return
        }
        let report = library.reload()
        if report.activated {
            acceptActivatedSnapshot(report.snapshot)
            status = "Reloaded registry \(report.snapshot.revision.uuidString.prefix(8))."
        } else {
            status = report.issues.first?.message
        }
    }

    func revert() {
        let discardedNewPackage = editSession?.createsNewPackage == true
        let active = library.snapshot()
        let adoptedPendingRegistry = pendingSnapshot != nil
            || active.revision != snapshot.revision
        snapshot = active
        pendingSnapshot = nil
        hasPendingRegistryUpdate = false
        selectInitialIfNeeded()
        reloadDraft()
        if validation.isValid {
            status = discardedNewPackage
                ? "Discarded the unsaved new Ability without installing it."
                : adoptedPendingRegistry
                ? "Discarded the draft and opened the active registry."
                : "Reverted to the active package."
        }
    }

    func save() {
        guard validation.isValid else {
            status = validation.issues.first?.message ?? "Fix validation errors before saving."
            return
        }
        guard let editSession else {
            status = "Reopen the Ability before saving this edit."
            return
        }
        let createsNewPackage = editSession.createsNewPackage
        do {
            let report = try library.saveEditedPackage(json: draft, session: editSession)
            snapshot = report.snapshot
            pendingSnapshot = nil
            hasPendingRegistryUpdate = false
            isDirty = false
            reloadDraft()
            status = createsNewPackage
                ? "Created and activated this Ability. Registry \(report.snapshot.revision.uuidString.prefix(8)) is active for new turns."
                : "Saved. Registry \(report.snapshot.revision.uuidString.prefix(8)) is active for new turns."
        } catch {
            status = error.localizedDescription
        }
    }

    func importPackage() {
        guard !isDirty else {
            status = "Save or revert the current draft before importing another package."
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.maryAbilityPackage]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importPackage(from: url)
    }

    func importPackage(from url: URL) {
        guard !isDirty else {
            status = "Save or revert the current draft before importing another package."
            return
        }
        do {
            try finishImport(from: url) { try library.importPackage(from: url) }
        } catch {
            status = error.localizedDescription
        }
    }

    private func finishImport(
        from url: URL,
        install: () throws -> AbilityLibraryReloadReport
    ) throws {
        do {
            let importedID = try AbilityPackageCodec.load(from: url).package.id
            let report = try install()
            snapshot = report.snapshot
            pendingSnapshot = nil
            hasPendingRegistryUpdate = false
            selectedPackageID = importedID
            reloadDraft()
            guard let active = report.snapshot.package(id: importedID) else {
                status = "The import completed, but \(importedID.rawValue) is not active."
                return
            }
            status = "Imported and activated \(active.package.ability.title) (\(importedID.rawValue))."
        } catch {
            status = error.localizedDescription
            throw error
        }
    }

    func exportPackage() {
        guard validation.isValid else {
            status = validation.issues.first?.message
                ?? "Fix validation errors before exporting this draft."
            return
        }
        guard let id = selectedPackageID, editSession != nil else {
            status = "Reopen the Ability before exporting this draft."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.maryAbilityPackage]
        panel.nameFieldStringValue = "\(id.rawValue).mary"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exportPackage(to: url)
    }

    func exportPackage(to url: URL) {
        guard validation.isValid else {
            status = validation.issues.first?.message
                ?? "Fix validation errors before exporting this draft."
            return
        }
        guard let editSession else {
            status = "Reopen the Ability before exporting this draft."
            return
        }
        do {
            try library.exportEditedPackage(
                json: draft,
                session: editSession,
                to: url)
            status = isDirty
                ? "Exported the current unsaved draft as \(url.lastPathComponent)."
                : "Exported \(url.lastPathComponent)."
        } catch {
            status = error.localizedDescription
        }
    }

    var selectedRecord: AbilityPackageRecord? {
        guard let selectedPackageID else { return nil }
        return snapshot.package(id: selectedPackageID)
    }

    var selectedSkills: [AbilityRuntimeSkill] {
        guard let selectedPackageID else { return [] }
        return snapshot.skills.filter { $0.packageID == selectedPackageID }
    }

    var selectedDependencies: [AbilityStudioDependencyPresentation] {
        guard let package = selectedRecord?.package else { return [] }
        return package.dependencies
            .map { dependency in
                AbilityStudioDependencyPresentation(
                    dependency: dependency,
                    installedPackage: snapshot.package(id: dependency.packageID)?.package)
            }
            .sorted { $0.packageID.rawValue < $1.packageID.rawValue }
    }

    var selectedApplication: AbilityStudioApplicationPresentation? {
        _ = applicationResolutionEpoch
        guard let package = selectedRecord?.package else { return nil }
        let realizedSkills = Set(snapshot.skills.lazy.compactMap { runtime -> SkillID? in
            guard runtime.availability.readiness == .ready,
                  let selected = runtime.availability.selectedBinding,
                  package.plugin.map({ plugin in
                      plugin.adapters.contains { $0.id == selected.adapterID }
                  }) == true,
                  runtime.reference.provider?.originPackageID == package.package.id
            else { return nil }
            return runtime.skill.id
        })
        return AbilityStudioApplicationPresentation(
            package: package,
            activeRealizedSkillCount: realizedSkills.count,
            applicationLocator: applicationLocator)
    }

    /// Provider implementations from the frozen registry, not the draft JSON.
    var selectedProviderRealizations: [AbilityStudioProviderRealizationPresentation] {
        _ = applicationResolutionEpoch
        let skillIDs = Set(selectedSkills.map(\.skill.id))
        guard !skillIDs.isEmpty else { return [] }

        var skillsByProvider: [AdapterProviderProvenance: Set<SkillID>] = [:]
        for realization in snapshot.plugins.skillRealizations
        where skillIDs.contains(realization.skillID) {
            skillsByProvider[realization.provider, default: []].insert(realization.skillID)
        }
        for runtime in selectedSkills {
            guard let provider = runtime.reference.provider,
                  provider.pluginClass == .runtime
            else { continue }
            skillsByProvider[provider, default: []].insert(runtime.skill.id)
        }

        return skillsByProvider.map { provider, skills in
            let carriedPlugin = provider.originPackageID
                .flatMap { snapshot.package(id: $0)?.package.plugin }
            let manifest = snapshot.adapterManifests.first {
                $0.resolvedProvider == provider
            }
            let applicationResolution = carriedPlugin.map {
                applicationLocator.resolve($0.application)
            }
            let activeSkills = Set(snapshot.skills.lazy.compactMap {
                runtime -> SkillID? in
                guard skills.contains(runtime.skill.id),
                      runtime.availability.readiness == .ready,
                      runtime.reference.provider == provider
                else { return nil }
                return runtime.skill.id
            })
            return AbilityStudioProviderRealizationPresentation(
                provider: provider,
                realizedSkillCount: skills.count,
                activeSkillCount: activeSkills.count,
                isAvailable: manifest?.isAvailable ?? false,
                unavailableReason: manifest?.unavailableReason,
                bundleIdentifiers: carriedPlugin?.application.bundleIdentifiers ?? [],
                bundleNames: carriedPlugin?.application.bundleNames ?? [],
                applicationResolution: applicationResolution,
                requiredPermissions: carriedPlugin.map { plugin in
                    plugin.adapters.flatMap(\.permissions)
                } ?? [])
        }.sorted {
            if $0.provider.pluginClass != $1.provider.pluginClass {
                return $0.provider.pluginClass.rawValue < $1.provider.pluginClass.rawValue
            }
            return $0.provider.pluginTitle < $1.provider.pluginTitle
        }
    }

    var canEditSelectedPackage: Bool {
        editSession != nil
    }

    var isCreatingNewPackage: Bool {
        editSession?.createsNewPackage == true
    }

    /// Dirty editor stays pinned to its lease snapshot. Registry adopts after Save or Revert.
    func handleLibraryEvent(_ event: AbilityLibraryEvent) {
        switch event {
        case .activated(let next):
            acceptActivatedSnapshot(next)
        case .rejected(let issues):
            if isDirty {
                hasPendingRegistryUpdate = true
                status = "A registry change was rejected. This draft remains pinned: \(issues.first?.message ?? "the changed package is invalid.")"
            } else {
                // Re-lease against current bytes, or close if they no longer match.
                reloadDraft()
                status = issues.first?.message ?? "The edited registry was rejected."
            }
        }
    }

    private func selectInitialIfNeeded() {
        if let selectedPackageID, snapshot.package(id: selectedPackageID) != nil { return }
        // The package changed under us; ids held in selection state belonged to
        // the old one.
        selectedPackageID = snapshot.records.first?.id
        clearSelectionState()
    }

    private func acceptActivatedSnapshot(_ next: AbilityRuntimeSnapshot) {
        guard next.revision != snapshot.revision else { return }
        guard !isDirty else {
            pendingSnapshot = next
            hasPendingRegistryUpdate = true
            status = "Registry changed on disk. This draft remains pinned; save may be rejected, or Revert to open the active version."
            return
        }
        pendingSnapshot = nil
        hasPendingRegistryUpdate = false
        snapshot = next
        selectInitialIfNeeded()
        reloadDraft()
    }

    private func reloadDraft() {
        guard let id = selectedPackageID, snapshot.package(id: id) != nil else {
            draft = ""
            validation = .init()
            editSession = nil
            isDirty = false
            isLocalDraft = false
            return
        }
        do {
            let session = try library.beginEditingPackage(id: id)
            editSession = session
            draft = session.draftJSON
            validation = library.validate(json: draft)
            isDirty = false
            isLocalDraft = session.createsLocalOverride
        } catch {
            draft = ""
            validation = .init(issues: [.init(
                severity: .error,
                code: "edit-session",
                path: "$",
                message: error.localizedDescription)])
            editSession = nil
            isDirty = false
            isLocalDraft = false
            status = error.localizedDescription
        }
    }
}
