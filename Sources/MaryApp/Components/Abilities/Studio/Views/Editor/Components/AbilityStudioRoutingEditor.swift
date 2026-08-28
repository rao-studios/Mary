import MaryBrain
import SwiftUI

struct AbilityStudioRoutingPolicyEditor: View {
    let policy: RoutingPolicySchema
    let path: String
    let onChange: (RoutingPolicySchema) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                AbilityStudioIntegerField(
                    "Preference",
                    path: "\(path).preference",
                    value: policy.preference) { value in
                    var next = policy
                    next.preference = value
                    onChange(next)
                }
                AbilityStudioTextField(
                    "Conflict group",
                    path: "\(path).conflictGroup",
                    text: Binding(
                        get: { policy.conflictGroup ?? "" },
                        set: { value in
                            var next = policy
                            next.conflictGroup = value.isEmpty ? nil : value
                            onChange(next)
                        }),
                    monospaced: true)
            }
            Picker("Conflict policy", selection: Binding(
                get: { policy.conflictPolicy },
                set: { value in
                    var next = policy
                    next.conflictPolicy = value
                    onChange(next)
                })) {
                ForEach(RoutingConflictPolicy.allCases, id: \.self) {
                    Text($0.rawValue).tag($0)
                }
            }
            AbilityStudioSchemaPath("\(path).conflictPolicy")

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Eligibility block").font(.callout.weight(.semibold))
                    Spacer()
                    if policy.eligibility == nil {
                        Button("Add Rule") {
                            var next = policy
                            next.eligibility = .init(kind: .any, children: [
                                .init(kind: .utteranceToken, value: "example"),
                            ])
                            onChange(next)
                        }
                    } else {
                        Button("Remove", role: .destructive) {
                            var next = policy
                            next.eligibility = nil
                            onChange(next)
                        }
                    }
                }
                if let predicate = policy.eligibility {
                    AbilityStudioPredicateBlock(
                        predicate: predicate,
                        path: "\(path).eligibility") { value in
                        var next = policy
                        next.eligibility = value
                        onChange(next)
                    }
                } else {
                    Text("No eligibility rule — routing relies on the Ability vocabulary and other evidence.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}

private struct AbilityStudioPredicateBlock: View {
    let predicate: RoutingPredicate
    let path: String
    let onChange: (RoutingPredicate) -> Void

    private var isGroup: Bool {
        predicate.kind == .all || predicate.kind == .any || predicate.kind == .not
    }

    private var carriesValue: Bool {
        !isGroup
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Image(systemName: isGroup ? "square.stack.3d.up" : "diamond")
                    .foregroundStyle(.blue)
                Picker("", selection: Binding(
                    get: { predicate.kind },
                    set: { kind in
                        var next = predicate
                        next.kind = kind
                        if kind == .all || kind == .any {
                            next.value = nil
                            if next.children.isEmpty {
                                next.children = [.init(kind: .utteranceToken, value: "example")]
                            }
                        } else if kind == .not {
                            next.value = nil
                            next.children = [next.children.first ?? .init(
                                kind: .utteranceToken, value: "example")]
                        } else {
                            next.children = []
                            if next.value == nil { next.value = "example" }
                        }
                        onChange(next)
                    })) {
                    ForEach(RoutingPredicate.Kind.allCases, id: \.self) {
                        Text($0.rawValue).tag($0)
                    }
                }
                .labelsHidden()
                if carriesValue {
                    TextField("value", text: Binding(
                        get: { predicate.value ?? "" },
                        set: { value in
                            var next = predicate
                            next.value = value
                            onChange(next)
                        }))
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                }
                Spacer()
            }
            AbilityStudioSchemaPath(path)
            if isGroup {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(predicate.children.enumerated()), id: \.offset) { index, child in
                        HStack(alignment: .top, spacing: 8) {
                            AnyView(AbilityStudioPredicateBlock(
                                predicate: child,
                                path: "\(path).children[\(index)]") { changed in
                                var next = predicate
                                next.children[index] = changed
                                onChange(next)
                            })
                            Button {
                                var next = predicate
                                next.children.remove(at: index)
                                onChange(next)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .disabled(predicate.kind == .not || predicate.children.count <= 1)
                        }
                    }
                    if predicate.kind != .not {
                        Button("Add condition") {
                            var next = predicate
                            next.children.append(.init(kind: .utteranceToken, value: "example"))
                            onChange(next)
                        }
                    }
                }
                .padding(.leading, 14)
                .overlay(alignment: .leading) {
                    Rectangle().fill(.blue.opacity(0.25)).frame(width: 2)
                }
            }
        }
        .padding(10)
        .background(.blue.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(.blue.opacity(0.16)))
    }
}
