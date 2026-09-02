import MaryBrain
import SwiftUI

// `draftBinding` and the unused-name helpers moved to Views/Kit/AbilityStudioBindings.swift.

struct AbilityStudioStageScroll<Content: View>: View {
    let title: String
    let introduction: String
    @ViewBuilder let content: Content

    init(
        title: String,
        introduction: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.introduction = introduction
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(title).font(.title2.weight(.semibold))
                    Text(introduction)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content
            }
            .padding(22)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }
}

struct AbilityStudioEditorSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    init(
        _ title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 13) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
        } label: {
            Label(title, systemImage: symbol).font(.headline)
        }
    }
}

struct AbilityStudioBlockCard<Content: View>: View {
    let number: Int
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    init(
        number: Int,
        title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) {
        self.number = number
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Text("\(number)")
                    .font(.caption.bold().monospacedDigit())
                    .frame(width: 23, height: 23)
                    .background(Color.accentColor, in: Circle())
                    .foregroundStyle(.white)
                Image(systemName: symbol).foregroundStyle(.secondary)
                Text(title).font(.callout.weight(.semibold))
                Spacer()
            }
            content
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator.opacity(0.6)))
    }
}

struct AbilityStudioTextField: View {
    let title: String
    let path: String
    @Binding var text: String
    var monospaced = false

    init(
        _ title: String,
        path: String,
        text: Binding<String>,
        monospaced: Bool = false
    ) {
        self.title = title
        self.path = path
        _text = text
        self.monospaced = monospaced
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.medium))
            TextField(title, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(monospaced ? .body.monospaced() : .body)
            AbilityStudioSchemaPath(path)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AbilityStudioTextArea: View {
    let title: String
    let path: String
    @Binding var text: String

    init(_ title: String, path: String, text: Binding<String>) {
        self.title = title
        self.path = path
        _text = text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.medium))
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 58, maxHeight: 100)
                .padding(4)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            AbilityStudioSchemaPath(path)
        }
    }
}

struct AbilityStudioIntegerField: View {
    let title: String
    let path: String
    let value: Int
    let onChange: (Int) -> Void

    init(_ title: String, path: String, value: Int, onChange: @escaping (Int) -> Void) {
        self.title = title
        self.path = path
        self.value = value
        self.onChange = onChange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.medium))
            TextField(title, value: Binding(get: { value }, set: onChange), format: .number)
                .textFieldStyle(.roundedBorder)
            AbilityStudioSchemaPath(path)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AbilityStudioDoubleField: View {
    let title: String
    let path: String
    let value: Double
    var range: ClosedRange<Double>?
    let onChange: (Double) -> Void

    init(
        _ title: String,
        path: String,
        value: Double,
        range: ClosedRange<Double>? = nil,
        onChange: @escaping (Double) -> Void
    ) {
        self.title = title
        self.path = path
        self.value = value
        self.range = range
        self.onChange = onChange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.medium))
            TextField(title, value: Binding(
                get: { value },
                set: { next in onChange(range.map { min(max(next, $0.lowerBound), $0.upperBound) } ?? next) }),
                format: .number)
                .textFieldStyle(.roundedBorder)
            AbilityStudioSchemaPath(path)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AbilityStudioSchemaPath: View {
    let path: String
    init(_ path: String) { self.path = path }

    var body: some View {
        Text(path)
            .font(.caption2.monospaced())
            .foregroundStyle(.tertiary)
            .textSelection(.enabled)
    }
}

struct AbilityStudioTagEditor: View {
    let title: String
    let path: String
    let values: [String]
    let onChange: ([String]) -> Void
    @State private var pending = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.medium))
            FlowLayout(spacing: 6) {
                ForEach(values, id: \.self) { value in
                    HStack(spacing: 4) {
                        Text(value).font(.caption.monospaced())
                        Button {
                            onChange(values.filter { $0 != value })
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2.bold())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.blue.opacity(0.1), in: Capsule())
                }
                TextField("Add…", text: $pending)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .frame(minWidth: 90)
                    .onSubmit(add)
            }
            .padding(7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(.separator))
            AbilityStudioSchemaPath(path)
        }
    }

    private func add() {
        let value = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !values.contains(value) else { return }
        onChange(values + [value])
        pending = ""
    }
}

struct AbilityStudioStringListEditor: View {
    let title: String
    let path: String
    let values: [String]
    let onChange: ([String]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).font(.caption.weight(.medium))
                Spacer()
                Button("Add") { onChange(values + [""]) }
                    .buttonStyle(.link)
            }
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                HStack(alignment: .firstTextBaseline) {
                    Text("\(index + 1)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    TextField(title, text: Binding(
                        get: { value },
                        set: { next in
                            var changed = values
                            changed[index] = next
                            onChange(changed)
                        }))
                        .textFieldStyle(.roundedBorder)
                    Button {
                        var changed = values
                        changed.remove(at: index)
                        onChange(changed)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                }
            }
            AbilityStudioSchemaPath(path)
        }
    }
}
