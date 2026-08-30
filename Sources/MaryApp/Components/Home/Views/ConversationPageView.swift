//
//  ConversationPageView.swift
//  Mary
//
//  WHAT: Conversation scroll — latest utterance full ink, history fading above.
//  OUT:  UtteranceView / StreamingUtteranceView / AbilityBadgeRow
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
            // VStack, not Lazy — bottom scroll-anchor needs real heights, not estimates.
            VStack(alignment: .leading, spacing: 28) {
                ForEach(Array(conversation.utterances.enumerated()), id: \.element.id) {
                    index, utterance in
                    // Depth passed in (not firstIndex per row — that was O(n²) per frame).
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
            // Chips ride with the stream (receipts already on the utterance). Not tappable while writing.
            VStack(alignment: .leading, spacing: .layer3) {
                StreamingUtteranceView(
                    text: streamVM.streamedText,
                    isThinking: streamVM.phase == .thinking
                )
                if !utterance.abilityBadges.isEmpty {
                    AbilityBadgeRow(
                        badges: utterance.abilityBadges,
                        actions: utterance.actions,
                        realmLensEntry: utterance.turnID.flatMap { realmLens.entries[$0] })
                }
            }
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
