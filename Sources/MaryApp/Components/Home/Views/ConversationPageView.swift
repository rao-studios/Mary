//
//  ConversationPageView.swift
//  Mary
//
//  The paper page: the conversation flowing down one scroll, the focal
//  (latest) utterance in full ink and history fading above it. Gita's
//  StoryPageView minus the markup layer.
//

import SwiftUI
import MaryRuntime

struct ConversationPageView: View {
    let conversation: Conversation
    let lastError: String?
    let bootStatus: String?
    @ObservedObject var streamVM: ConversationStreamViewModel
    /// Opens the Routes pane — Home's existing header toggle, threaded down
    /// so the place capsule can tap through to the row's full route.
    var onOpenRoutes: (() -> Void)? = nil

    /// The place lens — which place led each exchange, joined live from the
    /// trace log by turn id (RouterPaneView's owned-view-model pattern).
    @StateObject private var realmLens = RealmLensProvider()

    var body: some View {
        ScrollView {
            // VStack, not Lazy. Lazy rows are never measured until they are
            // materialized, so `.defaultScrollAnchor(.bottom)` re-derived the
            // pinned offset from ESTIMATED heights — and the rows here range
            // from a one-line user line to a multi-paragraph reply with chips,
            // so the estimate is badly wrong. Under a bottom `safeAreaInset`
            // whose own height moves (the live partial transcript), the anchor
            // could land past the true end of the content and show nothing but
            // page. Dragging re-synced it against real geometry, which is why
            // the wall came back "when I scroll up".
            //
            // Affordable because the transcript is bounded by the Settings
            // context window now; laziness was paying for a list that no
            // longer exists.
            VStack(alignment: .leading, spacing: 28) {
                ForEach(Array(conversation.utterances.enumerated()), id: \.element.id) {
                    index, utterance in
                    // Depth passed IN rather than looked up: `fade`/`blur`
                    // each ran a `firstIndex(where:)` over the whole
                    // conversation, per row, per render — O(n²) every frame,
                    // at up to 60 frames a second.
                    utteranceRow(utterance, depth: conversation.utterances.count - 1 - index)
                }
                footer
            }
            .frame(maxWidth: Paper.measure, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, .layer5)
            .padding(.top, .layer2)
            .padding(.bottom, .layer5)
        }
        .scrollIndicators(.hidden)
        .defaultScrollAnchor(.bottom)
        .background(Paper.page.ignoresSafeArea())
        .onAppear { realmLens.start() }
        .onDisappear { realmLens.stop() }
    }

    // MARK: - Rows

    @ViewBuilder
    private func utteranceRow(_ utterance: Utterance, depth: Int) -> some View {
        if streamVM.streamingUtteranceId == utterance.id, streamVM.phase != .idle {
            StreamingUtteranceView(
                text: streamVM.streamedText,
                isThinking: streamVM.phase == .thinking
            )
        } else {
            UtteranceView(
                utterance: utterance,
                inkOpacity: fade(depth),
                blurRadius: blur(depth),
                // Joined by the brain-turn id stamped on the bubble, never by
                // position. Old/restored rows carry no live trace entry and
                // simply show no capsule.
                realmLensEntry: utterance.turnID.flatMap { realmLens.entries[$0] },
                onOpenRoutes: onOpenRoutes
            )
        }
    }

    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: .layer2) {
            if let bootStatus {
                Text.note2(bootStatus)
                    .foregroundStyle(Paper.graphite.opacity(0.8))
            }
            if let lastError {
                Text.note2("Mary paused: \(lastError)")
                    .foregroundStyle(Color.red.opacity(0.6))
            }
        }
        .padding(.top, .layer3)
    }

    // MARK: - Focus fade

    /// `depth` is distance from the focal (last) row, handed down by the
    /// ForEach rather than searched for.
    private func fade(_ depth: Int) -> Double {
        switch depth {
        case 0: return 1.0
        case 1: return 0.72
        default: return 0.5
        }
    }

    private func blur(_ depth: Int) -> CGFloat {
        depth >= 2 ? 0.6 : 0
    }
}
