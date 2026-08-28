//
//  CorpusOperationsView.swift
//  Mary
//
//  What indexing actually did, newest first.
//
//  A skipped row earns its place here: "this file was unchanged, so nothing
//  was read, summarised, or deposited" is the efficiency claim made visible,
//  and without it a quiet pane and a broken pane look identical.
//

import MaryAmbient
import SwiftUI

struct CorpusOperationsView: View {

    @ObservedObject var vm: CorpusViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: .layer2) {
            if vm.operations.isEmpty {
                Text("Nothing yet. Activity appears here as Mary reads your work.")
                    .font(.marySans(11))
                    .foregroundStyle(Color.maryInk.opacity(0.5))
                    .padding(.top, .layer4)
            } else {
                ForEach(vm.operations) { operation in
                    row(operation)
                }
            }
        }
        .padding(.horizontal, .layer4)
    }

    private func row(_ operation: UnitIndexOperation) -> some View {
        HStack(alignment: .top, spacing: .layer2) {
            Image(systemName: symbol(operation.kind))
                .font(.system(size: 10))
                .foregroundStyle(color(operation.kind))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(headline(operation))
                    .font(.marySans(11))
                    .foregroundStyle(Color.maryInk.opacity(0.85))
                if let detail = operation.detail {
                    Text(detail)
                        .font(.maryMono(9))
                        .foregroundStyle(Color.maryInk.opacity(0.45))
                }
            }
            Spacer()
            Text(operation.at, style: .relative)
                .font(.maryMono(9))
                .foregroundStyle(Color.maryInk.opacity(0.35))
        }
        .padding(.vertical, 2)
    }

    private func headline(_ operation: UnitIndexOperation) -> String {
        let subject = (operation.subject as NSString).lastPathComponent
        switch operation.kind {
        case .crawled: return "Read around \(subject)"
        case .indexed: return "Indexed \(subject)"
        case .skippedUnchanged: return "Skipped \(subject)"
        case .annotated: return "Summarised \(subject)"
        case .deposited: return "Remembered \(subject)"
        case .invalidated: return "Will re-read \(subject)"
        case .forgotten: return "Forgot \(subject)"
        case .labelsPinned: return "Pinned labels on \(subject)"
        // Not a file — the subject is a scope and a dimension, so it keeps
        // its full name rather than being reduced to a path component.
        case .evicted: return "Let go of \(operation.subject)"
        // Deliberately plain. The elevation is invisible in the work; this
        // row is the only place it exists at all.
        case .failed: return "Could not remember \(subject)"
        }
    }

    private func symbol(_ kind: UnitIndexOperation.Kind) -> String {
        switch kind {
        case .crawled: return "point.3.connected.trianglepath.dotted"
        case .indexed: return "square.stack.3d.up"
        case .skippedUnchanged: return "equal.circle"
        case .annotated: return "text.quote"
        case .deposited: return "checkmark.circle"
        case .invalidated: return "arrow.clockwise"
        case .forgotten: return "trash"
        case .labelsPinned: return "pin.fill"
        case .evicted: return "wind"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private func color(_ kind: UnitIndexOperation.Kind) -> Color {
        switch kind {
        case .failed: return .maryError
        case .deposited: return .maryGreen
        case .labelsPinned, .invalidated: return .maryGold
        case .skippedUnchanged, .evicted: return Color.maryInk.opacity(0.25)
        default: return Color.maryInk.opacity(0.5)
        }
    }
}
