//
//  TotemsNodesView.swift
//  Mary
//
//  WHAT: Fleet as Seer sees it, disk as it is — independent sections/authorities.
//

import SwiftUI

struct TotemsNodesView: View {

    @ObservedObject var vm: TotemExplorerViewModel
    @Binding var selectedNodeID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: .layer3) {
            SectionLabel("Fleet")
            if let notice = vm.nodesNotice {
                // Rendered beside whatever stale fleet is still on screen —
                // the notice explains, it never suppresses.
                Text(notice)
                    .font(.marySans(11))
                    .foregroundStyle(Color.maryError)
            }
            if let header = vm.fleetHeader {
                fleetCard(header)
                ForEach(vm.nodeRows) { row in
                    nodeCard(row)
                }
            } else if vm.nodesNotice == nil {
                Text("Reaching Seer for the fleet…")
                    .font(.marySans(11))
                    .foregroundStyle(Color.maryInk.opacity(0.5))
            }

            SectionLabel("On disk")
                .padding(.top, .layer3)
            if let summary = vm.diskSummary {
                diskSummaryCard(summary)
                ForEach(vm.diskRows) { row in
                    diskRow(row)
                }
            } else {
                Text("Scanning the totem-db directory…")
                    .font(.marySans(11))
                    .foregroundStyle(Color.maryInk.opacity(0.5))
            }
        }
        .padding(.horizontal, .layer4)
    }

    // MARK: - Fleet

    private func fleetCard(_ header: TotemFleetHeader) -> some View {
        MaryCard {
            VStack(alignment: .leading, spacing: .layer2) {
                if header.enabled {
                    // FlowLayout, not HStack: stats keep intrinsic width and
                    // wrap as whole tiles on a thin pane (MaryStat refuses
                    // mid-word compression).
                    FlowLayout(spacing: .layer4, lineSpacing: .layer2) {
                        MaryStat(value: "\(header.nodeCount)", label: "Nodes")
                        MaryStat(value: "\(header.totalDocumentCount)", label: "Documents")
                        MaryStat(value: "\(header.totalGroupCount)", label: "Groups")
                    }
                } else {
                    // Seer's honest "no fleet" — distinct from unreachable.
                    Text("No totem nodes are registered with the mothership.")
                        .font(.marySans(11))
                        .foregroundStyle(Color.maryInk.opacity(0.6))
                }
                Text("Mothership \(header.mothershipID)")
                    .font(.maryMono(9))
                    .foregroundStyle(Color.maryInk.opacity(0.4))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func nodeCard(_ row: TotemNodeRow) -> some View {
        let isOpen = selectedNodeID == row.id
        return MaryCard {
            VStack(alignment: .leading, spacing: .layer2) {
                Button {
                    selectedNodeID = isOpen ? nil : row.id
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: .layer2) {
                            StatusDot(color: row.isActive ? .maryGreen : .maryError)
                            Text(row.id)
                                .font(.maryMono(10))
                                .foregroundStyle(Color.maryInk)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if row.isConfiguredNode {
                                MaryBadge(text: "YOURS")
                            }
                            Spacer()
                            Text(row.lastSeenLine)
                                .font(.maryMono(9))
                                .foregroundStyle(Color.maryInk.opacity(0.4))
                        }
                        Text("\(row.host) · \(row.portLine)")
                            .font(.marySans(10))
                            .foregroundStyle(Color.maryInk.opacity(0.55))
                        if let statsLine = row.statsLine {
                            Text(statsLine)
                                .font(.marySans(10))
                                .foregroundStyle(Color.maryInk.opacity(0.65))
                        }
                    }
                }
                .buttonStyle(.plain)

                if isOpen {
                    Divider()
                    FlowLayout(spacing: .layer4, lineSpacing: .layer2) {
                        MaryStat(value: row.isActive ? "yes" : "no", label: "Active")
                        MaryStat(value: row.acceptingStorage ? "accepting" : "closed", label: "Storage")
                        if let stats = row.stats {
                            MaryStat(value: "\(stats.availableDocumentCount)", label: "Available")
                            MaryStat(value: "\(stats.ownerCount)", label: "Owners")
                        }
                    }
                    if row.stats == nil {
                        Text("No stats — registered, but not answering the stats fan-out.")
                            .font(.marySans(10))
                            .foregroundStyle(Color.maryInk.opacity(0.45))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Disk

    private func diskSummaryCard(_ summary: TotemDiskSummary) -> some View {
        MaryCard {
            VStack(alignment: .leading, spacing: .layer2) {
                FlowLayout(spacing: .layer4, lineSpacing: .layer2) {
                    MaryStat(value: "\(summary.nodeCount)", label: "DBs")
                    MaryStat(value: "\(summary.orphanCount)", label: "Orphaned")
                    MaryStat(value: "\(summary.documentCount)", label: "Documents")
                    MaryStat(value: "\(summary.partsCount)", label: "Parts")
                    MaryStat(value: summary.totalLine, label: "Size")
                }
                Text(summary.root)
                    .font(.maryMono(9))
                    .foregroundStyle(Color.maryInk.opacity(0.4))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if summary.liveNodeID == nil {
                    Text("No live identity — neither a configured node id nor a node-id file. Every DB below is orphaned.")
                        .font(.marySans(10))
                        .foregroundStyle(Color.maryInk.opacity(0.5))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func diskRow(_ row: TotemDiskRow) -> some View {
        HStack(alignment: .top, spacing: .layer2) {
            StatusDot(color: row.isLive ? .maryGreen : Color.maryInk.opacity(0.2))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: .layer2) {
                    Text(row.id)
                        .font(.maryMono(10))
                        .foregroundStyle(Color.maryInk.opacity(row.isLive ? 1 : 0.6))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if row.isLive {
                        MaryBadge(text: "LIVE", color: .maryGreen)
                    }
                }
                Text(row.layersLine)
                    .font(.marySans(9))
                    .foregroundStyle(Color.maryInk.opacity(0.45))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(row.sizeLine)
                    .font(.maryMono(9))
                    .foregroundStyle(Color.maryInk.opacity(0.55))
                if let modified = row.modifiedLine {
                    Text(modified)
                        .font(.maryMono(9))
                        .foregroundStyle(Color.maryInk.opacity(0.35))
                }
            }
        }
        .padding(.vertical, 2)
    }
}
