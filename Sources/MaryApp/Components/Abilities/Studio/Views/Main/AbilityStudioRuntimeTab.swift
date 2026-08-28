import MaryBrain
import SwiftUI

// MARK: - Native faculties

/// Plugin Abilities are data-only. This tab makes the execution boundary
/// visible without offering a source-code surface: every displayed step is a
/// member of Mary's closed, compiled native-interaction vocabulary.
struct AbilityStudioRuntimeTab: View {
    @ObservedObject var model: AbilityStudioViewModel

    var body: some View {
        if let package = model.draftPackage,
           let plugin = package.plugin {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    purityBanner
                    applicationSection(plugin)
                    adaptersSection(plugin)
                    operationsSection(plugin)
                }
                .padding()
            }
        } else if model.draftPackage == nil {
            ContentUnavailableView(
                "Draft does not decode",
                systemImage: "exclamationmark.triangle",
                description: Text("Fix the JSON in the Schema tab first."))
        } else {
            ContentUnavailableView(
                "No application provider",
                systemImage: "hand.point.up.left",
                description: Text("This Ability defines expertise or policy and does not teach Mary to operate an application."))
        }
    }

    private var purityBanner: some View {
        GroupBox {
            Label(
                "Pure Ability — Mary executes every interaction through compiled native faculties.",
                systemImage: "checkmark.shield.fill")
                .foregroundStyle(.green)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("The package may select bounded shortcuts, printable text entry, pointer movement and gestures, scrolling, window rebinds, cleanup, waits, and postconditions. It cannot carry source code, name an executable, launch a shell, emit control-bearing text, or author its own receipt.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func applicationSection(_ plugin: PluginSchema) -> some View {
        GroupBox("Target application") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Application") { Text(plugin.application.title) }
                LabeledContent("Bundle identity") {
                    Text(plugin.application.bundleIdentifiers.joined(separator: ", "))
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
                LabeledContent("Verified against") {
                    if plugin.application.supportedReleases.isEmpty {
                        Text("Any release")
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .trailing, spacing: 2) {
                            ForEach(
                                Array(plugin.application.supportedReleases.enumerated()),
                                id: \.offset
                            ) { _, release in
                                Text("\(release.shortVersion) (\(release.bundleVersion))")
                                    .font(.system(.callout, design: .monospaced))
                            }
                        }
                    }
                }
                LabeledContent("Activation") {
                    Text(plugin.application.activation == .requireFrontmost
                         ? "Require frontmost"
                         : "Bring forward only when already running")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func adaptersSection(_ plugin: PluginSchema) -> some View {
        GroupBox("Mary-owned adapters") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(plugin.adapters, id: \.id) { adapter in
                    HStack(alignment: .firstTextBaseline) {
                        Label(adapter.title, systemImage: "hand.point.up.left.fill")
                        Spacer()
                        Text(adapter.id.rawValue)
                            .font(.system(.caption, design: .monospaced))
                        Text(adapter.permissions.map(\.rawValue).joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func operationsSection(_ plugin: PluginSchema) -> some View {
        GroupBox("Declarative operations") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(plugin.operations.sorted { $0.operation < $1.operation }) { operation in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(operation.title).font(.headline)
                            Spacer()
                            Text(operation.operation)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Text(operation.summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        ForEach(operation.steps) { step in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: symbol(for: step.kind))
                                    .frame(width: 16)
                                Text(step.id)
                                    .font(.system(.caption, design: .monospaced))
                                Text(description(for: step))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if !operation.cleanupSteps.isEmpty {
                            Text("Cleanup")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(operation.cleanupSteps) { step in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Image(systemName: symbol(for: step.kind))
                                        .frame(width: 16)
                                    Text(step.id)
                                        .font(.system(.caption, design: .monospaced))
                                    Text(description(for: step))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        Text("Verifies: " + operation.postconditions.map(\.rawValue).joined(separator: ", "))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                    Divider()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func symbol(for kind: PluginRecipeStepKind) -> String {
        switch kind {
        case .keyChord: return "command"
        case .typeText: return "text.cursor"
        case .pointerMove: return "cursorarrow.motionlines"
        case .pointerClick: return "cursorarrow.click"
        case .pointerDrag, .pointerSquareDrag: return "arrow.up.left.and.arrow.down.right"
        case .scroll: return "scroll"
        case .rebindFocusedWindow: return "macwindow.on.rectangle"
        case .captureAccessibilityAnchor: return "viewfinder.rectangular"
        case .wait: return "timer"
        }
    }

    private func description(for step: PluginRecipeStepSchema) -> String {
        switch step.kind {
        case .keyChord:
            let chord = (step.modifiers.map(\.rawValue) + [step.key?.rawValue ?? "?"])
                .joined(separator: "+")
            return "Key chord \(chord)"
        case .typeText:
            if let input = step.text?.input {
                return "Enter bounded text from input \(input)"
            }
            return "Enter bounded printable text"
        case .pointerMove:
            return "Move to a normalized point in \(coordinateSpace(for: step))"
        case .pointerClick:
            return "Click a normalized point in \(coordinateSpace(for: step))"
        case .pointerDrag:
            return "Drag across a normalized rectangle in \(coordinateSpace(for: step))"
        case .pointerSquareDrag:
            return "Drag a screen-square inside \(coordinateSpace(for: step))"
        case .scroll:
            return "Scroll with bounded horizontal or vertical deltas"
        case .rebindFocusedWindow:
            return "Accept the target process's newly focused window"
        case .captureAccessibilityAnchor:
            let locator = step.accessibilityLocator
            return "Capture \(locator?.role.rawValue ?? "?") · \(locator?.identifier ?? "?") as \(step.captureAnchor ?? "?")"
        case .wait:
            return "Bounded wait \(step.durationSeconds ?? 0)s"
        }
    }

    private func coordinateSpace(for step: PluginRecipeStepSchema) -> String {
        step.coordinateSpace.map { "captured area \($0)" }
            ?? "the verified content surface"
    }
}
