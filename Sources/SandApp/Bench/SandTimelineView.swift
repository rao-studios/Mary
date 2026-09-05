//
//  SandTimelineView.swift
//  Sand
//
//  WHAT: The run, line by line — every act, every refusal, in the order the
//        machine layer performed them.
//  IN:   SandTraceModel entries + the monitor's per-lane tallies
//  OUT:  the bottom of the bench pane
//  PIN:  A REFUSAL IS NEVER SUMMARIZED AWAY. `ComputerUseRefusalReason` exists
//        so a skipped act says why it skipped; that line is usually the answer
//        someone opened this app for, so it is printed in full and in red.
//        Sequence numbers are shown because they are monotonic: a gap means
//        events were dropped, not that nothing happened.
//
import MaryComputerUse
import SwiftUI

struct SandTimelineView: View {
    @ObservedObject var trace: SandTraceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(trace.entries) { entry in
                            row(entry).id(entry.id)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .onChange(of: trace.entries.count) { _, _ in
                    guard let last = trace.entries.last else { return }
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Computer use").font(.caption.bold())
            if let snapshot = trace.snapshot {
                Text("\(snapshot.totalActs) acts · \(snapshot.totalRefusals) refused")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                if snapshot.sense.walks > 0 {
                    Text("\(snapshot.sense.walks) walks")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            laneTallies
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// Only lanes that actually did something. A row of zeroes for eight idle
    /// lanes would bury the one that acted.
    @ViewBuilder
    private var laneTallies: some View {
        if let snapshot = trace.snapshot {
            HStack(spacing: 6) {
                ForEach(ComputerUseLane.allCases, id: \.self) { lane in
                    if let tally = snapshot.lanes[lane], tally.acts + tally.refusals > 0 {
                        Text("\(lane.rawValue) \(tally.acts)/\(tally.refusals)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(tally.refusals > 0 ? Color.orange : .secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: SandTraceEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(offsetText(entry))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 62, alignment: .trailing)
            content(entry)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func content(_ entry: SandTraceEntry) -> some View {
        switch entry.kind {
        case .runBegan(let invocation, let runID, let realization):
            VStack(alignment: .leading, spacing: 1) {
                Text("dispatch \(invocation)  ·  run \(runID.prefix(8))")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                if !realization.isEmpty {
                    Text("via \(realization)")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
        case .act(let act):
            HStack(spacing: 6) {
                Text("#\(act.sequence)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text("\(act.lane.rawValue)/\(act.name)")
                    .font(.system(size: 11, design: .monospaced))
                if !act.detail.isEmpty {
                    Text(act.detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        case .refusal(let refusal):
            HStack(alignment: .top, spacing: 6) {
                Text("#\(refusal.sequence)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text("\(refusal.lane.rawValue)/\(refusal.name) refused")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.red)
                Text(refusal.reason.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        case .record(let record):
            VStack(alignment: .leading, spacing: 1) {
                Text("ledger · \(record.disposition.rawValue) · \(record.action.intention)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.blue)
                if let target = record.action.target {
                    Text("acted on \(target.role) “\(target.label)” in \(target.windowTitle)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                // WHICH HANDS ACTUALLY ANSWERED. A fallback adapter's success reads
                // exactly like the primary's until the trail is named.
                if !record.receiptWords.isEmpty {
                    Text(record.receiptWords)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        case .runEnded(let summary, let ok):
            Text(summary)
                .font(.system(size: 11))
                .foregroundStyle(ok ? Color.green : Color.red)
        case .browser(let line, let isRefusal):
            HStack(spacing: 6) {
                Text("browsing")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(isRefusal ? Color.red : Color.teal)
                Text(line)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(isRefusal ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            }
        case .external(let text):
            HStack(spacing: 6) {
                Text("external")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.purple)
                Text(text)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        case .note(let text):
            Text(text).font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    private func offsetText(_ entry: SandTraceEntry) -> String {
        guard let offset = entry.offset else { return "" }
        return String(format: "+%.0f ms", offset * 1000)
    }
}
