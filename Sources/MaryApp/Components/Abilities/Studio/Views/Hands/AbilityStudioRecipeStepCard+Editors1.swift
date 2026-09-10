//
//  AbilityStudioRecipeStepCard+Editors1.swift
//  Mary
//
//  WHAT: Key chords, typed text and pointer blocks.
//  IN:   AbilityStudioRecipeStepCard (sibling split)
//

import MaryBrain
import SwiftUI

extension AbilityStudioRecipeStepCard {

    var keyChordEditor: some View {
        VStack(alignment: .leading, spacing: 9) {
            // Free chord; design-lane Escape / Control-Tab constraints are gone.
            do {
                HStack {
                    Text(step.chordLabel)
                        .font(.title2.monospaced().weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
                    Picker("Key", selection: Binding(
                        get: { step.key ?? .n },
                        set: { value in mutateStep { $0.key = value } })) {
                        ForEach(PluginKey.allCases, id: \.self) {
                            Text($0.editorLabel).tag($0)
                        }
                    }
                    Spacer()
                }
                FlowLayout(spacing: 7) {
                    ForEach(PluginKeyModifier.editorOrder, id: \.self) { modifier in
                        Toggle(isOn: Binding(
                            get: { step.modifiers.contains(modifier) },
                            set: { enabled in
                                mutateStep {
                                    if enabled, !$0.modifiers.contains(modifier) {
                                        $0.modifiers.append(modifier)
                                    } else if !enabled {
                                        $0.modifiers.removeAll { $0 == modifier }
                                    }
                                }
                            })) {
                            Text(modifier.editorGlyph)
                        }
                        .toggleStyle(.button)
                    }
                }
                Text("One virtual key only. Use a Type Text block for bounded printable text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    var textEditor: some View {
        VStack(alignment: .leading, spacing: 9) {
            let expression = step.text ?? .init(value: "Text")
            if !textInputNames.isEmpty {
                Picker("Text source", selection: Binding(
                    get: { expression.input == nil },
                    set: { fixed in
                        mutateStep {
                            $0.text = fixed
                                ? .init(value: expression.value
                                    ?? expression.defaultValue
                                    ?? "Text")
                                : .init(
                                    input: textInputNames.first ?? "",
                                    defaultValue: expression.value
                                        ?? expression.defaultValue)
                        }
                    })) {
                        Text("Fixed").tag(true)
                        Text("Input").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
            }
            if let input = expression.input {
                Picker("Text input", selection: Binding(
                    get: { input },
                    set: { value in
                        mutateStep {
                            $0.text = .init(
                                input: value,
                                defaultValue: expression.defaultValue)
                        }
                    })) {
                        ForEach(textInputNames, id: \.self) { Text($0).tag($0) }
                    }
                AbilityStudioTextField(
                    "Fallback (optional)",
                    path: "\(stepPath).text.defaultValue",
                    text: Binding(
                        get: { expression.defaultValue ?? "" },
                        set: { value in
                            mutateStep {
                                $0.text = .init(
                                    input: input,
                                    defaultValue: value.isEmpty ? nil : value)
                            }
                        }))
            } else {
                AbilityStudioTextField(
                    "Text",
                    path: "\(stepPath).text.value",
                    text: Binding(
                        get: { expression.value ?? "Text" },
                        set: { value in
                            mutateStep { $0.text = .init(value: value) }
                        }))
            }
            Label(
                "Mary enters printable text with native keyboard events. Line breaks and control characters remain outside the package vocabulary.",
                systemImage: "keyboard")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

}
