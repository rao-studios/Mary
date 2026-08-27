//
//  TotemsGraphView.swift
//  Mary
//
//  The entity graph, asked on demand: seed + kind + hops + documents in,
//  entities, edges and cited docs out — plus the repair bench. EVERY repair
//  is irreversible or expensive, so every one of them funnels through the
//  single confirmation dialog below; nothing in this file mutates on a bare
//  button.
//
//  The seed TextField stages in local @State on purpose: the Center's
//  @Store debounces 200 ms per keystroke, which blurs typing. It lands in
//  the bound Center state only on submit.
//

import MaryTotem
import SwiftUI
import MaryRuntime

struct TotemsGraphView: View {

    @ObservedObject var vm: TotemExplorerViewModel
    @Binding var graphSeed: String
    @Binding var graphKindFilter: String?
    @Binding var graphHops: Int
    @Binding var graphIncludesDocuments: Bool
    @Binding var selectedEntityID: String?

    @State private var seedDraft = ""

    /// The one gate every repair passes: set by a button, performed only by
    /// the dialog's confirm action.
    @State private var pendingRepair: PendingRepair?

    /// Repair drafts, view-local like the seed — a rename mid-type is not a
    /// click the Center should remember.
    @State private var renameDraft = ""
    @State private var mergeDraft = ""

    private enum PendingRepair: Equatable {
        case rename(id: String, name: String)
        case merge(from: String, into: String)
        case delete(id: String)
        case setKind(id: String, kind: String)
        case deleteRelationship(id: String)
        case reextract(documentID: String)

        var title: String {
            switch self {
            case .rename(_, let name):
                return "Rename this entity to “\(name)”?"
            case .merge(_, let into):
                return "Merge this entity into \(into)?"
            case .delete:
                return "Delete this entity?"
            case .setKind(_, let kind):
                return "Set this entity's kind to “\(kind)”?"
            case .deleteRelationship:
                return "Delete this relationship?"
            case .reextract:
                return "Re-extract this document?"
            }
        }

        var message: String {
            switch self {
            case .rename:
                return "Every relationship keeps pointing at the renamed entity. Renaming onto an existing name may collapse the two."
            case .merge:
                return "The merged-from entity disappears and its relationships move. This can't be undone."
            case .delete:
                return "The entity and its relationships are removed. This can't be undone."
            case .setKind:
                return "Re-kinding may collapse this entity into an existing one of that kind."
            case .deleteRelationship:
                return "The edge is removed. This can't be undone."
            case .reextract:
                return "Totem replays its LLM extractor over the document — this costs model calls and can take up to two minutes."
            }
        }

        var isDestructive: Bool {
            switch self {
            case .merge, .delete, .deleteRelationship: return true
            case .rename, .setKind, .reextract: return false
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: .layer3) {
            controls

            if let notice = vm.graphNotice {
                Text(notice)
                    .font(.marySans(11))
                    .foregroundStyle(Color.maryError)
            }
            if let notice = vm.mutationNotice {
                Text(notice)
                    .font(.marySans(11))
                    .foregroundStyle(Color.maryGold)
            }
            if vm.isMutating {
                HStack(spacing: .layer2) {
                    ProgressView().controlSize(.small)
                    Text("Asking Totem to mutate the graph…")
                        .font(.marySans(11))
                        .foregroundStyle(Color.maryInk.opacity(0.5))
                }
            }

            if let graph = vm.graph {
                results(graph)
            } else if !vm.isQuerying, vm.graphNotice == nil {
                Text("Seed with an entity or free text — or run empty to browse the most-mentioned entities.")
                    .font(.marySans(11))
                    .foregroundStyle(Color.maryInk.opacity(0.5))
            }
        }
        .padding(.horizontal, .layer4)
        .onAppear { seedDraft = graphSeed }
        .confirmationDialog(
            pendingRepair?.title ?? "",
            isPresented: Binding(
                get: { pendingRepair != nil },
                set: { if !$0 { pendingRepair = nil } }),
            titleVisibility: .visible
        ) {
            Button(
                pendingRepair?.isDestructive == true ? "Do it" : "Go ahead",
                role: pendingRepair?.isDestructive == true ? .destructive : nil
            ) {
                if let repair = pendingRepair { perform(repair) }
                pendingRepair = nil
            }
            Button("Cancel", role: .cancel) { pendingRepair = nil }
        } message: {
            Text(pendingRepair?.message ?? "")
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: .layer2) {
            HStack(spacing: .layer2) {
                TextField("entity or free text", text: $seedDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.marySans(11))
                    .onSubmit { runQuery() }
                Button {
                    runQuery()
                } label: {
                    if vm.isQuerying {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Ask")
                    }
                }
                .buttonStyle(.maryQuiet)
            }

            FlowLayout(spacing: 4, lineSpacing: 4) {
                ForEach(TotemGraphPolicy.maryKinds, id: \.name) { kind in
                    MaryChip(
                        label: kind.name,
                        isOn: graphKindFilter == kind.name
                    ) {
                        graphKindFilter = graphKindFilter == kind.name ? nil : kind.name
                    }
                }
            }

            HStack(spacing: .layer3) {
                HStack(spacing: 4) {
                    Text("Hops")
                        .font(.marySans(10))
                        .foregroundStyle(Color.maryInk.opacity(0.5))
                    // 1–3 only: the UI never offers 0 (the wire would repair
                    // it, but two layers should not need to agree on that).
                    ForEach(1...3, id: \.self) { hops in
                        MaryChip(label: "\(hops)", isOn: graphHops == hops) {
                            graphHops = hops
                        }
                    }
                }
                Toggle("Documents", isOn: $graphIncludesDocuments)
                    .toggleStyle(.checkbox)
                    .font(.marySans(10))
                Spacer()
            }
        }
    }

    private func runQuery() {
        graphSeed = seedDraft
        vm.runGraphQuery(
            seed: seedDraft,
            kind: graphKindFilter,
            hops: graphHops,
            includeDocuments: graphIncludesDocuments)
    }

    // MARK: - Results

    @ViewBuilder
    private func results(_ graph: GraphQueryResult) -> some View {
        // Whole-graph totals vs the returned slice — how much the query
        // did NOT show.
        Text("\(graph.entities.count) of \(graph.entityCount) entities · \(graph.relationships.count) of \(graph.relationshipCount) relationships")
            .font(.maryMono(9))
            .foregroundStyle(Color.maryInk.opacity(0.45))

        ForEach(graph.entities) { entity in
            entityCard(entity, in: graph)
        }
        if graph.entities.isEmpty {
            Text("Nothing matched.")
                .font(.marySans(11))
                .foregroundStyle(Color.maryInk.opacity(0.5))
        }

        // Gated on the EXECUTED query's shape, not the live toggle — flipping
        // Documents after a run must neither hide fetched documents nor imply
        // unfetched ones. The toggle shapes only the NEXT query.
        if vm.lastGraphRequest?.includeDocuments == true, !graph.documents.isEmpty {
            SectionLabel("Cited documents")
                .padding(.top, .layer2)
            ForEach(graph.documents) { document in
                documentRow(document)
            }
        }
    }

    private func entityCard(_ entity: GraphEntity, in graph: GraphQueryResult) -> some View {
        let isOpen = selectedEntityID == entity.id
        return MaryCard(padding: 12) {
            VStack(alignment: .leading, spacing: .layer2) {
                Button {
                    selectedEntityID = isOpen ? nil : entity.id
                    renameDraft = entity.name
                    mergeDraft = ""
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: .layer2) {
                            Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.maryInk.opacity(0.4))
                            Text(entity.name)
                                .font(.marySans(12, weight: .medium))
                                .lineLimit(1)
                            MaryBadge(text: entity.kind)
                            Spacer()
                            if entity.score > 0 {
                                Text(String(format: "%.2f", entity.score))
                                    .font(.maryMono(9))
                                    .foregroundStyle(Color.maryGold)
                            }
                        }
                        Text("\(entity.mentionCount) mentions · \(entity.documentIDs.count) documents")
                            .font(.marySans(9))
                            .foregroundStyle(Color.maryInk.opacity(0.45))
                    }
                }
                .buttonStyle(.plain)

                if isOpen {
                    Divider()
                    neighborhood(of: entity, in: graph)
                    repairs(for: entity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func neighborhood(of entity: GraphEntity, in graph: GraphQueryResult) -> some View {
        let edges = graph.relationships.filter {
            $0.subjectID == entity.id || $0.objectID == entity.id
        }
        if edges.isEmpty {
            Text("No edges in this slice.")
                .font(.marySans(10))
                .foregroundStyle(Color.maryInk.opacity(0.45))
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(edges) { edge in
                    edgeRow(edge, in: graph)
                }
            }
        }
    }

    private func edgeRow(_ edge: GraphRelationship, in graph: GraphQueryResult) -> some View {
        HStack(spacing: .layer2) {
            // Endpoints are entity IDS; the helper resolves a label and
            // falls back to the raw id when limit pruned the endpoint.
            Text("\(TotemExplorerViewModel.entityName(edge.subjectID, in: graph)) —\(edge.predicate)→ \(TotemExplorerViewModel.entityName(edge.objectID, in: graph))")
                .font(.marySans(10))
                .foregroundStyle(Color.maryInk.opacity(0.75))
                .lineLimit(2)
            Text("×\(edge.weight)")
                .font(.maryMono(9))
                .foregroundStyle(Color.maryInk.opacity(0.35))
            Spacer()
            Button {
                pendingRepair = .deleteRelationship(id: edge.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.maryError.opacity(0.7))
            }
            .buttonStyle(.plain)
            .disabled(repairsDisabled)
        }
    }

    // MARK: - Repairs (armed here, FIRED only by the dialog)

    private var repairsDisabled: Bool {
        !vm.isTotemHealthy || vm.isMutating
    }

    private func repairs(for entity: GraphEntity) -> some View {
        VStack(alignment: .leading, spacing: .layer2) {
            SectionLabel("Repair")
            HStack(spacing: .layer2) {
                TextField("new name", text: $renameDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.maryMono(10))
                Button("Rename") {
                    let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty, name != entity.name else { return }
                    pendingRepair = .rename(id: entity.id, name: name)
                }
                .buttonStyle(.maryQuiet)
                .disabled(repairsDisabled)
            }
            HStack(spacing: .layer2) {
                TextField("merge into (entity id)", text: $mergeDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.maryMono(10))
                Button("Merge") {
                    let into = mergeDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !into.isEmpty, into != entity.id else { return }
                    pendingRepair = .merge(from: entity.id, into: into)
                }
                .buttonStyle(.maryQuiet)
                .disabled(repairsDisabled)
            }
            HStack(spacing: .layer2) {
                Menu("Set kind") {
                    ForEach(TotemGraphPolicy.maryKinds, id: \.name) { kind in
                        Button(kind.name) {
                            pendingRepair = .setKind(id: entity.id, kind: kind.name)
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(repairsDisabled)
                Button("Delete") {
                    pendingRepair = .delete(id: entity.id)
                }
                .buttonStyle(.maryQuiet)
                .disabled(repairsDisabled)
                Spacer()
            }
            if !vm.isTotemHealthy {
                Text("Totem isn't running — repairs need its HTTP port.")
                    .font(.marySans(9))
                    .foregroundStyle(Color.maryInk.opacity(0.45))
            }
        }
    }

    private func documentRow(_ document: GraphDocumentRef) -> some View {
        HStack(spacing: .layer2) {
            Image(systemName: "doc.text")
                .font(.system(size: 9))
                .foregroundStyle(Color.maryInk.opacity(0.4))
            VStack(alignment: .leading, spacing: 1) {
                Text(document.name.isEmpty ? document.id : document.name)
                    .font(.marySans(11))
                    .foregroundStyle(Color.maryInk.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(document.id)
                    .font(.maryMono(9))
                    .foregroundStyle(Color.maryInk.opacity(0.35))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Re-extract") {
                pendingRepair = .reextract(documentID: document.id)
            }
            .buttonStyle(.maryQuiet)
            .disabled(repairsDisabled)
        }
        .padding(.vertical, 1)
    }

    /// The dialog's confirm action — the ONLY caller of the VM's repair
    /// passthroughs in this file.
    private func perform(_ repair: PendingRepair) {
        switch repair {
        case .rename(let id, let name):
            vm.renameEntity(id: id, name: name)
        case .merge(let from, let into):
            vm.mergeEntities(from: from, into: into)
        case .delete(let id):
            vm.deleteEntity(id: id)
        case .setKind(let id, let kind):
            vm.setEntityKind(id: id, kind: kind)
        case .deleteRelationship(let id):
            vm.deleteRelationship(id: id)
        case .reextract(let documentID):
            vm.reextractDocument(id: documentID)
        }
    }
}
