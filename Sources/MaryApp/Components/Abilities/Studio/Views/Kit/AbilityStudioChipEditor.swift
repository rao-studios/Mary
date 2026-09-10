//
//  AbilityStudioChipEditor.swift
//  Mary
//
//  WHAT: Removable-chip list with an inline add field; numbered string list.
//  IN:   Tune pane vocabularies, Advanced prose lists.
//  OUT:  AbilityStudioKit chrome. Add/remove semantics ported from the old TagEditor.
//

import SwiftUI

/// A set of short values — trigger tokens, phrases, aliases. Adding commits on
/// submit; removing commits at once. Duplicates and blanks are refused silently.
struct StudioChipEditor: View {
    let label: String?
    let values: [String]
    var placeholder: String = "add…"
    var tint: Color?
    var isEditable: Bool = true
    let onChange: ([String]) -> Void

    @State private var pending = ""

    init(
        _ label: String? = nil,
        values: [String],
        placeholder: String = "add…",
        tint: Color? = nil,
        isEditable: Bool = true,
        onChange: @escaping ([String]) -> Void
    ) {
        self.label = label
        self.values = values
        self.placeholder = placeholder
        self.tint = tint
        self.isEditable = isEditable
        self.onChange = onChange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: .layer1) {
            if let label { StudioLabel(label) }
            FlowLayout(spacing: .layer1) {
                ForEach(values, id: \.self) { value in
                    chip(value)
                }
                if isEditable {
                    TextField(placeholder, text: $pending)
                        .textFieldStyle(.plain)
                        .font(.maryMono(10))
                        .foregroundStyle(Color.maryInk)
                        .frame(minWidth: 64)
                        .onSubmit(add)
                }
            }
        }
    }

    private func chip(_ value: String) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(.maryMono(10))
                .foregroundStyle(tint ?? Color.maryInk.opacity(0.7))
            if isEditable {
                Button {
                    onChange(values.filter { $0 != value })
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle((tint ?? Color.maryInk).opacity(0.55))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill((tint ?? Color.maryInk).opacity(tint == nil ? 0.06 : 0.12)))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func add() {
        let value = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !values.contains(value) else {
            pending = ""
            return
        }
        onChange(values + [value])
        pending = ""
    }
}

/// Numbered sentences — operating-policy prose, where order carries meaning and
/// a value is long enough to want its own line.
struct StudioStringListEditor: View {
    let label: String
    let values: [String]
    var placeholder: String = ""
    let onChange: ([String]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: .layer2) {
            HStack {
                StudioLabel(label)
                Spacer()
                StudioAddButton(title: "Add") { onChange(values + [""]) }
            }
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                HStack(alignment: .top, spacing: .layer2) {
                    Text("\(index + 1)")
                        .font(.maryMono(9))
                        .foregroundStyle(Color.maryInk.opacity(0.35))
                        .frame(width: 12, alignment: .trailing)
                        .padding(.top, 6)
                    StudioField(value: value, placeholder: placeholder) { next in
                        var changed = values
                        changed[index] = next
                        onChange(changed)
                    }
                    Button {
                        var changed = values
                        changed.remove(at: index)
                        onChange(changed)
                    } label: {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.maryInk.opacity(0.3))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 5)
                }
            }
        }
    }
}
