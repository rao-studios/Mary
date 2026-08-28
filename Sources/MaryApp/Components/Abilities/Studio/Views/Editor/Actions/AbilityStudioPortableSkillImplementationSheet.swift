import MaryBrain
import SwiftUI

/// Adds Remote Hands to an already-defined portable Skill without copying its
/// semantic contract into the application package.
@MainActor
struct AbilityStudioPortableSkillImplementationSheet: View {
    @ObservedObject var model: AbilityStudioViewModel
    let package: MaryAbilityPackage
    let onCreated: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var selectedOptionID: String?
    @State private var selectedKey: PluginKey?
    @State private var modifiers: Set<PluginKeyModifier> = []

    private var coverage: AbilityStudioActionCoveragePresentation {
        AbilityStudioActionCoveragePresentation(
            package: package,
            snapshot: model.snapshot)
    }

    private var options: [AbilityStudioActionCoveragePresentation.PortableSkillOption] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return coverage.implementationOptions }
        return coverage.implementationOptions.filter { option in
            [
                option.ownerTitle,
                option.ownerPackageID.rawValue,
                option.skillTitle,
                option.skillID.rawValue,
                option.summary,
            ].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var selectedOption: AbilityStudioActionCoveragePresentation.PortableSkillOption? {
        guard let selectedOptionID else { return nil }
        return coverage.implementationOptions.first { $0.id == selectedOptionID }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                optionBrowser
                    .frame(width: 380)
                Divider()
                implementationDetails
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Divider()
            footer
        }
        .frame(minWidth: 820, minHeight: 620)
        .onAppear(perform: selectInitialOption)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: "arrow.triangle.branch")
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 40, height: 40)
                .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 4) {
                Text("Implement a Portable Skill")
                    .font(.title2.weight(.semibold))
                Text("Choose meaning owned by another Ability, then give it one bounded native starting block. The source Skill keeps policy, parameters, and receipts; this file supplies only application-specific hands.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label("No package code", systemImage: "checkmark.shield.fill")
                .font(.caption)
                .foregroundStyle(.green)
        }
        .padding(18)
    }

    private var optionBrowser: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Find a portable Skill", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(12)

            HStack {
                Text("\(coverage.implementationOptions.count) contracts not implemented")
                Spacer()
                Text("\(coverage.implementationOptions.filter { $0.compatibility.canImplement }.count) ready")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.bottom, 9)

            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if options.isEmpty {
                        ContentUnavailableView(
                            "No matching Skills",
                            systemImage: "magnifyingglass",
                            description: Text("Try a package name, Skill name, or semantic verb."))
                            .padding(.top, 30)
                    } else {
                        ForEach(options) { option in
                            optionRow(option)
                        }
                    }
                }
                .padding(10)
            }
        }
        .background(.regularMaterial)
    }

    private func optionRow(
        _ option: AbilityStudioActionCoveragePresentation.PortableSkillOption
    ) -> some View {
        Button {
            selectedOptionID = option.id
            selectedKey = nil
            modifiers = []
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(option.skillTitle)
                        .font(.callout.weight(.semibold))
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 6)
                    if option.isDeclaredDependency {
                        Text("DEPENDENCY")
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.11), in: Capsule())
                            .foregroundStyle(.blue)
                    }
                }
                Text("\(option.ownerTitle) · \(option.skillID.rawValue)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if option.compatibility.canImplement {
                    Label("Ready for current Remote Hands blocks", systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                } else {
                    Label("Needs Mary faculty", systemImage: "lock.circle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selectedOptionID == option.id
                    ? Color.accentColor.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(
                        selectedOptionID == option.id
                            ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.12))
            }
        }
        .buttonStyle(.plain)
        .opacity(option.compatibility.canImplement ? 1 : 0.78)
        .help(option.compatibility.reason ?? "This portable contract can use the current macUI grammar.")
        .accessibilityHint(
            option.compatibility.reason
                ?? "Select to configure one bounded native starting block.")
    }

    @ViewBuilder
    private var implementationDetails: some View {
        if let option = selectedOption {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(option.skillTitle)
                            .font(.title3.weight(.semibold))
                        Text(option.summary)
                            .foregroundStyle(.secondary)
                        Label(
                            "Contract owned by \(option.ownerTitle)",
                            systemImage: "shippingbox")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }

                    if let reason = option.compatibility.reason {
                        needsFaculty(reason)
                    } else {
                        contractSummary(option)
                        starterEditor(option)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView(
                "Choose a compatible Skill",
                systemImage: "arrow.left",
                description: Text("Orange contracts remain visible so missing Mary faculties are explicit rather than silently absent."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func needsFaculty(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("This contract cannot be expressed by current macUI blocks", systemImage: "lock.shield")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(reason)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("The honest next step is a typed faculty compiled into Mary. Studio will not approximate it with executable source, control-bearing text, or a weaker contract.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(13)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func contractSummary(
        _ option: AbilityStudioActionCoveragePresentation.PortableSkillOption
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Inherited contract").font(.headline)
            LabeledContent("Skill") {
                Text(option.skillID.rawValue).font(.body.monospaced())
            }
            LabeledContent("Source package") {
                Text(option.ownerPackageID.rawValue).font(.body.monospaced())
            }
            LabeledContent("Authorized targets") {
                Text(option.compatibility.targetClasses.joined(separator: ", "))
                    .font(.caption.monospaced())
                    .multilineTextAlignment(.trailing)
            }
            Text(option.isDeclaredDependency
                 ? "The required dependency is already declared."
                 : "Creating this implementation adds the source package as a required dependency.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(13)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func starterEditor(
        _ option: AbilityStudioActionCoveragePresentation.PortableSkillOption
    ) -> some View {
        switch option.compatibility.starter {
        case .keyChord:
            VStack(alignment: .leading, spacing: 11) {
                Text("First native block").font(.headline)
                Text("Choose the exact shortcut this application uses for the portable action. After creation, the ordinary block editor can add bounded text, pointer movement and gestures, scrolling, focused-window rebinds, cleanup, and waits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Picker("Key", selection: $selectedKey) {
                        Text("Choose a key…").tag(Optional<PluginKey>.none)
                        ForEach(PluginKey.allCases, id: \.self) { key in
                            Text(key.editorLabel).tag(Optional(key))
                        }
                    }
                    .frame(maxWidth: 240)
                    if let selectedKey {
                        Text((orderedModifiers.map(\.editorGlyph) + [selectedKey.editorLabel]).joined())
                            .font(.title2.monospaced().weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.purple.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                    }
                    Spacer()
                }
                HStack(spacing: 7) {
                    ForEach(PluginKeyModifier.editorOrder, id: \.self) { modifier in
                        Toggle(isOn: Binding(
                            get: { modifiers.contains(modifier) },
                            set: { enabled in
                                if enabled { modifiers.insert(modifier) }
                                else { modifiers.remove(modifier) }
                            })) {
                            Text(modifier.editorGlyph)
                        }
                        .toggleStyle(.button)
                    }
                }
            }
        case .boundedVerification:
            VStack(alignment: .leading, spacing: 7) {
                Text("First native block").font(.headline)
                Label("Bounded verification wait · 0.1 seconds", systemImage: "timer")
                    .foregroundStyle(.orange)
                Text("This read-class Skill has no native-input authority. Mary will only verify that the exact application remains frontmost with a focused window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case nil:
            EmptyView()
        }
    }

    private var footer: some View {
        HStack {
            if let option = selectedOption, option.compatibility.canImplement {
                Label(
                    option.compatibility.starter == .keyChord
                        ? "One closed key chord will be created"
                        : "One bounded verification block will be created",
                    systemImage: "square.stack.3d.up")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { dismiss() }
            Button("Add Implementation", action: createImplementation)
                .buttonStyle(.borderedProminent)
                .disabled(!canCreate)
        }
        .padding(14)
        .background(.bar)
    }

    private var orderedModifiers: [PluginKeyModifier] {
        PluginKeyModifier.editorOrder.filter(modifiers.contains)
    }

    private var canCreate: Bool {
        guard let option = selectedOption,
              option.compatibility.canImplement else { return false }
        if option.compatibility.starter == .keyChord {
            return selectedKey != nil
        }
        return true
    }

    private func selectInitialOption() {
        selectedOptionID = coverage.implementationOptions.first {
            $0.isDeclaredDependency && $0.compatibility.canImplement
        }?.id ?? coverage.implementationOptions.first {
            $0.compatibility.canImplement
        }?.id ?? coverage.implementationOptions.first?.id
    }

    private func createImplementation() {
        guard canCreate,
              let option = selectedOption,
              let ownerPackage = model.snapshot.package(id: option.ownerPackageID)?.package
        else { return }

        let step: PluginRecipeStepSchema
        switch option.compatibility.starter {
        case .keyChord:
            guard let selectedKey else { return }
            step = .init(
                id: "perform",
                kind: .keyChord,
                key: selectedKey,
                modifiers: orderedModifiers)
        case .boundedVerification:
            step = .init(
                id: "verify",
                kind: .wait,
                durationSeconds: 0.1)
        case nil:
            return
        }

        var createdOperation: String?
        let didCreate = model.mutateAuthoringDocument { document in
            createdOperation = try document.addPluginOperation(
                title: option.skillTitle,
                summary: option.summary,
                steps: [step],
                realizing: option.skillID,
                ownerPackage: ownerPackage,
                targetClasses: option.compatibility.targetClasses)
        }
        guard didCreate, let createdOperation else { return }
        onCreated(createdOperation)
        dismiss()
    }
}
