//
//  AbilityStudioRecipeStepCard+Editors2.swift
//

import MaryBrain
import SwiftUI

extension AbilityStudioRecipeStepCard {

    var waitEditor: some View {
        AbilityStudioDoubleField(
            "Wait seconds",
            path: "\(stepPath).durationSeconds",
            value: step.durationSeconds ?? 0.1,
            range: Double.leastNonzeroMagnitude...PluginValidator.maximumWaitSeconds) { value in
            mutateStep { $0.durationSeconds = value }
        }
    }

    var accessibilityAnchorEditor: some View {
        let locator = step.accessibilityLocator ?? .init(
            role: .group,
            identifier: "accessibility-element")
        return VStack(alignment: .leading, spacing: 9) {
            Text("Resolve one unique public-Accessibility element inside the pinned window and capture its live screen frame. This read-only block emits no mouse or keyboard input.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Picker("Exact role", selection: Binding(
                    get: { locator.role },
                    set: { role in
                        mutateStep {
                            $0.accessibilityLocator = .init(
                                role: role,
                                identifier: locator.identifier)
                        }
                    })) {
                    ForEach(PluginAccessibilityRole.allCases, id: \.self) {
                        Text($0.rawValue).tag($0)
                    }
                }
                AbilityStudioTextField(
                    "Exact Accessibility identifier",
                    path: "\(stepPath).accessibilityLocator.identifier",
                    text: Binding(
                        get: { locator.identifier },
                        set: { identifier in
                            mutateStep {
                                $0.accessibilityLocator = .init(
                                    role: locator.role,
                                    identifier: identifier)
                            }
                        }),
                    monospaced: true)
            }
            AbilityStudioTextField(
                "Capture coordinate area as",
                path: "\(stepPath).captureAnchor",
                text: Binding(
                    get: { step.captureAnchor ?? "" },
                    set: { value in
                        switch owner {
                        case .callable:
                            model.mutateAuthoringDocument {
                                try $0.renameCapturedCoordinateSpace(
                                    on: step.id,
                                    in: operation.operation,
                                    to: value.isEmpty ? nil : value)
                            }
                        }
                    }),
                monospaced: true)
        }
    }

    var coordinateSpaceEditor: some View {
        Picker("Coordinate space", selection: Binding(
            get: { step.coordinateSpace ?? "content" },
            set: { value in
                mutateStep {
                    $0.coordinateSpace = value == "content" ? nil : value
                }
            })) {
                ForEach(availableCoordinateSpaces, id: \.self) { space in
                    Text(coordinateSpaceTitle(space))
                        .tag(space)
                }
            }
            .frame(maxWidth: 300)
    }

    func coordinateSpaceTitle(_ space: String) -> String {
        if space == "content" { return "Window content" }
        if planOwnedCoordinateSpaces.contains(space) {
            return "Plan calibration · \(space)"
        }
        return "Captured · \(space)"
    }

    var scrollEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("Horizontal", isOn: Binding(
                    get: { step.deltaX != nil },
                    set: { enabled in
                        mutateStep {
                            $0.deltaX = enabled ? .init(value: 0) : nil
                        }
                    }))
                    .disabled(step.deltaX != nil && step.deltaY == nil)
                Toggle("Vertical", isOn: Binding(
                    get: { step.deltaY != nil },
                    set: { enabled in
                        mutateStep {
                            $0.deltaY = enabled ? .init(value: -120) : nil
                        }
                    }))
                    .disabled(step.deltaY != nil && step.deltaX == nil)
                Spacer()
            }
            HStack(alignment: .top, spacing: 10) {
                if let deltaX = step.deltaX {
                    AbilityStudioScalarExpressionEditor(
                        label: "Horizontal delta",
                        path: "\(stepPath).deltaX",
                        expression: deltaX,
                        inputNames: scrollInputNames,
                        valueRange: -10_000...10_000,
                        valueLabel: "Scroll points",
                        fixedDefault: 0) { expression in
                        mutateStep { $0.deltaX = expression }
                    }
                }
                if let deltaY = step.deltaY {
                    AbilityStudioScalarExpressionEditor(
                        label: "Vertical delta",
                        path: "\(stepPath).deltaY",
                        expression: deltaY,
                        inputNames: scrollInputNames,
                        valueRange: -10_000...10_000,
                        valueLabel: "Scroll points",
                        fixedDefault: -120) { expression in
                        mutateStep { $0.deltaY = expression }
                    }
                }
            }
            AbilityStudioDoubleField(
                "Scroll duration",
                path: "\(stepPath).durationSeconds",
                value: step.durationSeconds ?? 0.15,
                range: 0...PluginValidator.maximumWaitSeconds) { value in
                mutateStep { $0.durationSeconds = value }
            }
        }
    }

    var rebindEditor: some View {
        VStack(alignment: .leading, spacing: 9) {
            // No creation-surface placeholder; design lane is gone.
            do {
                Label(
                    "After an action opens another window, accept that process's newly focused window as the rest of this ordinary callable recipe's target.",
                    systemImage: "macwindow.on.rectangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Require a genuinely new window", isOn: Binding(
                    get: { step.requiresWindowChange == true },
                    set: { enabled in
                        mutateStep {
                            $0.requiresWindowChange = enabled ? true : nil
                        }
                    }))
                Text("Enable this only for an ordinary callable rebind whose preceding action must move to a new public-AX window identity.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                AbilityStudioSchemaPath("\(stepPath).requiresWindowChange")
            }
        }
    }

    func pointerOptions(showsClickCount: Bool) -> some View {
        HStack {
            Picker("Button", selection: Binding(
                get: { step.button ?? .left },
                set: { value in mutateStep { $0.button = value } })) {
                ForEach(PluginPointerButton.allCases, id: \.self) {
                    Text($0.rawValue.capitalized).tag($0)
                }
            }
            if showsClickCount {
                Stepper(
                    "Clicks: \(step.clickCount ?? 1)",
                    value: Binding(
                        get: { step.clickCount ?? 1 },
                        set: { value in mutateStep { $0.clickCount = value == 1 ? nil : value } }),
                    in: 1...3)
            }
            Spacer()
        }
    }

}
