//
//  TotemsLedgerView.swift
//  Mary
//
//  The app-side write mirror: what Mary SENT versus what Totem HOLDS.
//  Units carry the builder's deposit sentence; operations are the raw feed,
//  newest first. The Corpus pane manages these records — this tab only asks
//  whether they made it into the totem, so it reads and never mutates.
//

import MaryAmbient
import SwiftUI

struct TotemsLedgerView: View {

    @ObservedObject var vm: TotemExplorerViewModel
    @Binding var selectedUnitKey: String?

    var body: some View {
        // THE UNIT AND OPERATION LANES ARE NOT IN THIS CUT. They showed the
        // code-index crawl — which files were read, what each deposit did —
        // and that corpus is deferred. What is left is the ledger's actual
        // subject: what Mary deposited and what she retrieved.
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
