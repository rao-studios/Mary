//
//  AbilityStudioKit.swift
//  Mary
//
//  WHAT: The Studio's controls, in Mary's design language.
//  IN:   Studio panes, header, rail, drawer.
//  OUT:  Paper / Color.mary* / Font.mary* only — never a stock GroupBox or .roundedBorder.
//  PIN:  Text commits on submit or focus loss. Per-keystroke writes re-encode the
//        whole package under the library lock; a field must not do that.
//

import SwiftUI

// MARK: - Pane

/// A titled surface. `isFocused` draws the highlight ring the panes use to say
/// which one owns the keyboard.
struct StudioPane<Content: View>: View {
    let title: String
    var isFocused: Bool = false
    /// Greedy panes take the height their column has left; hugging panes take
    /// only what their content needs. Tune hugs, Recipe and Skills fill.
    var fills: Bool = true
    var trailing: AnyView?
    @ViewBuilder var content: Content

    init(
        _ title: String,
        isFocused: Bool = false,
        fills: Bool = true,
        @ViewBuilder trailing: () -> some View = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.isFocused = isFocused
        self.fills = fills
        self.trailing = AnyView(trailing())
        self.content = content()
    }

    var body: some View {
        MaryCard(padding: .layer4) {
            VStack(alignment: .leading, spacing: .layer3) {
                HStack(spacing: .layer2) {
                    SectionLabel(title)
                    Spacer(minLength: .layer2)
                    trailing
                }
                content
                if fills { Spacer(minLength: 0) }
            }
            .frame(
                maxWidth: .infinity,
                maxHeight: fills ? .infinity : nil,
                alignment: .topLeading)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Paper.highlight, lineWidth: 2)
                .opacity(isFocused ? 1 : 0))
    }
}

// MARK: - Labels

/// Field caption. Smaller and quieter than `SectionLabel`, which titles a pane.
struct StudioLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.marySans(10))
            .foregroundStyle(Color.maryInk.opacity(0.5))
    }
}

/// Machine path, for the drawer only. The panes speak plain words.
struct StudioSchemaPath: View {
    let path: String
    init(_ path: String) { self.path = path }
    var body: some View {
        Text(path)
            .font(.maryMono(9))
            .foregroundStyle(Color.maryInk.opacity(0.35))
            .textSelection(.enabled)
    }
}

/// Caption under a control, for the sentence that explains what a knob means.
struct StudioNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.marySans(9.5))
            .foregroundStyle(Color.maryInk.opacity(0.48))
            .lineSpacing(1.5)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Text

/// One-line text. Commits on submit or focus loss, never per keystroke.
struct StudioField: View {
    let label: String?
    let value: String
    var placeholder: String = ""
    var mono: Bool = false
    var isEditable: Bool = true
    /// An inner `.font` wins over one applied outside, so callers that want a
    /// different face — the header's serif title — pass it here.
    var font: Font?
    /// Reads as plain text until pointed at. For the one field that is also a
    /// heading, where a permanent well would shout.
    var quiet: Bool = false
    let onCommit: (String) -> Void

    @State private var draft: String = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    init(
        _ label: String? = nil,
        value: String,
        placeholder: String = "",
        mono: Bool = false,
        isEditable: Bool = true,
        font: Font? = nil,
        quiet: Bool = false,
        onCommit: @escaping (String) -> Void
    ) {
        self.label = label
        self.value = value
        self.placeholder = placeholder
        self.mono = mono
        self.isEditable = isEditable
        self.font = font
        self.quiet = quiet
        self.onCommit = onCommit
    }

    private var wellOpacity: Double {
        guard quiet else { return 1 }
        return (hovering || focused) ? 1 : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: .layer1) {
            if let label { StudioLabel(label) }
            Group {
                if isEditable {
                    TextField(placeholder, text: $draft)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .onSubmit(commit)
                } else {
                    Text(draft.isEmpty ? placeholder : draft)
                        .foregroundStyle(Color.maryInk.opacity(draft.isEmpty ? 0.3 : 0.6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(font ?? (mono ? .maryMono(11) : .marySans(12)))
            .foregroundStyle(Color.maryInk)
            .padding(.horizontal, .layer2)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isEditable ? Color.maryFill : Color.maryInk.opacity(0.025))
                    .opacity(wellOpacity))
            .animation(.easeOut(duration: 0.12), value: wellOpacity)
        }
        .onHover { hovering = $0 }
        .onAppear { draft = value }
        // An outside edit (revert, reload, another pane) reaches a field that is
        // not being typed into. One that IS focused keeps what the user typed.
        .onChange(of: value) { _, next in if !focused { draft = next } }
        .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
    }

    private func commit() {
        guard draft != value else { return }
        onCommit(draft)
    }
}

/// Multi-line prose. Same commit discipline as `StudioField`.
struct StudioTextArea: View {
    let label: String?
    let value: String
    var minHeight: CGFloat = 54
    /// Commit on every keystroke. Only for view-local state — a package field
    /// re-encodes and re-validates the whole draft, which is why the default
    /// waits for submit or focus loss.
    var live: Bool = false
    let onCommit: (String) -> Void

    @State private var draft: String = ""
    @FocusState private var focused: Bool

    init(
        _ label: String? = nil,
        value: String,
        minHeight: CGFloat = 54,
        live: Bool = false,
        onCommit: @escaping (String) -> Void
    ) {
        self.label = label
        self.value = value
        self.minHeight = minHeight
        self.live = live
        self.onCommit = onCommit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: .layer1) {
            if let label { StudioLabel(label) }
            TextEditor(text: $draft)
                .font(.marySans(12))
                .foregroundStyle(Color.maryInk)
                .scrollContentBackground(.hidden)
                .focused($focused)
                .frame(minHeight: minHeight)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.maryFill))
        }
        .onAppear { draft = value }
        .onChange(of: value) { _, next in if !focused { draft = next } }
        .onChange(of: draft) { _, _ in if live { commit() } }
        .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
    }

    private func commit() {
        guard draft != value else { return }
        onCommit(draft)
    }
}

// MARK: - Numbers

/// Bounded integer with a stepper. Commits immediately — there is no partial
/// integer to protect, and the value is clamped before it leaves.
struct StudioIntField: View {
    let label: String?
    let value: Int
    var range: ClosedRange<Int> = 0...300
    let onCommit: (Int) -> Void

    init(
        _ label: String? = nil,
        value: Int,
        range: ClosedRange<Int> = 0...300,
        onCommit: @escaping (Int) -> Void
    ) {
        self.label = label
        self.value = value
        self.range = range
        self.onCommit = onCommit
    }

    var body: some View {
        HStack(spacing: .layer2) {
            if let label { StudioLabel(label) }
            Text("\(value)")
                .font(.maryMono(11))
                .foregroundStyle(Color.maryInk)
                .frame(minWidth: 30, alignment: .trailing)
                .padding(.horizontal, .layer2)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.maryFill))
            Stepper("") {
                onCommit(min(range.upperBound, value + 5))
            } onDecrement: {
                onCommit(max(range.lowerBound, value - 5))
            }
            .labelsHidden()
        }
    }
}

/// Seconds, and any other bounded double. Commits on release, not while dragging.
struct StudioSlider: View {
    let label: String?
    let value: Double
    var range: ClosedRange<Double>
    var format: (Double) -> String
    let onCommit: (Double) -> Void

    @State private var live: Double = 0
    @State private var isDragging = false

    var body: some View {
        HStack(spacing: .layer2) {
            if let label { StudioLabel(label) }
            Slider(
                value: Binding(get: { isDragging ? live : value }, set: { live = $0 }),
                in: range,
                onEditingChanged: { editing in
                    isDragging = editing
                    if editing { live = value } else { onCommit(live) }
                })
            .controlSize(.small)
            .tint(Color.maryGold)
            .frame(width: 120)
            Text(format(isDragging ? live : value))
                .font(.maryMono(11))
                .foregroundStyle(Color.maryInk)
        }
        .onAppear { live = value }
    }
}

// MARK: - Menus

/// Label plus chevron over a closed case set. Menus commit immediately.
struct StudioMenuPicker<Value: Hashable>: View {
    let label: String?
    let value: Value
    let options: [Value]
    let title: (Value) -> String
    let onSelect: (Value) -> Void

    var body: some View {
        HStack(spacing: .layer2) {
            if let label { StudioLabel(label) }
            Menu {
                ForEach(options, id: \.self) { option in
                    Button(title(option)) { onSelect(option) }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(title(value))
                        .font(.marySans(11))
                        .foregroundStyle(Color.maryInk)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Color.maryInk.opacity(0.45))
                }
                .padding(.horizontal, .layer2)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.maryFill))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

// MARK: - Buttons

/// A bare symbol button, the Home header's idiom.
struct StudioIconButton: View {
    let symbol: String
    let help: String
    var isOn: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(isOn ? Paper.ink : Paper.ink.opacity(0.7))
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(isOn ? Color.maryFill : .clear))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Dashed capsule for "add one more" — a row, a step, a recipe.
struct StudioAddButton: View {
    let title: String
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .semibold))
                Text(title).font(.marySans(11))
            }
            .foregroundStyle(Color.maryInk.opacity(0.62))
            .padding(.horizontal, .layer3)
            .padding(.vertical, 5)
            .background(
                Capsule().strokeBorder(
                    Color.maryGold.opacity(0.45),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
    }
}

// MARK: - Pill

/// The recipe row's chrome: a capsule that can go red when its step will not run.
struct StudioPill<Content: View>: View {
    var isAlarmed: Bool = false
    var isSelected: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: .layer2) { content }
            .padding(.leading, .layer3)
            .padding(.trailing, .layer2)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.maryFill))
            .overlay(
                Capsule().strokeBorder(
                    isAlarmed ? Color.maryError : Color.maryBorder,
                    lineWidth: isAlarmed ? 1.5 : 1))
            .overlay(
                Capsule()
                    .strokeBorder(Paper.highlight, lineWidth: 2)
                    .padding(-2)
                    .opacity(isSelected ? 1 : 0))
    }
}

/// Owner attribution inside a pill or on a tile — the ability a thing came from.
struct StudioOwnerChip: View {
    let title: String
    let tint: Color

    var body: some View {
        Text(title)
            .font(.marySans(9, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(tint.opacity(0.12)))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}
