//
//  ThreadsLedgerView.swift
//  Mary
//
//  WHAT: App-side write mirror — what Mary sent vs what Thread holds. Read-only.
//  IN:   ThreadExplorerViewModel. Corpus pane mutates these records.
//

import MaryAmbient
import SwiftUI

struct ThreadsLedgerView: View {

    @ObservedObject var vm: ThreadExplorerViewModel
    @Binding var selectedUnitKey: String?

    var body: some View {
        // Ledger is deposits and retrievals; unit/operation crawl lanes are out.
        VStack(alignment: .leading, spacing: .layer3) {
            SectionLabel("Ledger")
            Text("Deposits and retrievals appear here as Mary uses her memory.")
                .font(.marySans(11))
                .foregroundStyle(Color.maryInk.opacity(0.5))
        }
        .padding(.horizontal, .layer4)
    }

    // MARK: - Fields

    private func field(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name.uppercased())
                .font(.maryMono(8))
                .foregroundStyle(Color.maryInk.opacity(0.35))
            Text(value)
                .font(.marySans(11))
                .foregroundStyle(Color.maryInk.opacity(0.8))
                .textSelection(.enabled)
        }
    }

    // MARK: - Operations

}
