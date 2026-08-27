//
//  VoiceStatusBar.swift
//  Mary
//
//  The floating bar under the page (Fleet chrome on Gita paper): mic toggle,
//  pipeline state chip, level meter, and the typed composer — the no-voice
//  test path. The mic side goes live in the voice-loop phase; until then it
//  reports "voice arrives soon".
//

import MaryAmbient
import SwiftUI
import MaryRuntime

struct VoiceStatusBar: View {
    let isSessionActive: Bool
    let phase: VoicePhase
    let audioLevel: Float
    let partialTranscript: String
    let isMicEnabled: Bool
    let isSendEnabled: Bool
    /// How many detached routines are still executing in the background.
    var runningRoutines: Int = 0
    /// Unprompted speech. Lives HERE rather than in the header trio, because
    /// those three mean "this pane is open" and wearing their tint for "this
    /// capability is armed" would make the header say two kinds of thing in
    /// one voice. This bar is where voice STATE is already reported.
    /// "Hey Mary" standby: no session, but a wake-only microphone is armed.
    /// Config-derived (wake enabled + app ready + session off) rather than a
    /// Center.State field — the Start loop's tail resets that state wholesale.
    var isStandingBy: Bool = false
    /// Arm / disarm. Two controls rather than one three-state cycle: cycling
    /// three states on a single glyph means every change of mind costs two
    /// taps and a guess about which way round it goes.
    /// Watching ⇄ speaking. Only shown while armed — there is no mode to
    /// choose when she is off, and a dead control is worse than no control.
    let onMicToggle: () -> Void
    let onSend: (String) -> Void

    @State private var draft: String = ""
    @FocusState private var composerFocused: Bool

    var body: some View {
        MaryCard(padding: 14) {
            VStack(alignment: .leading, spacing: .layer3) {
                HStack(spacing: .layer4) {
                    micButton
                    HStack(spacing: .layer2) {
                    }
                    stateChip
                    if runningRoutines > 0 {
                        HStack(spacing: .layer2) {
                            StatusDot(color: .maryGold)
                            SectionLabel(runningRoutines == 1
                                ? "still working"
                                : "\(runningRoutines) running")
                        }
                        .transition(.opacity)
                    }
                    Spacer()
                    LevelMeter(level: audioLevel)
                }
                if !partialTranscript.isEmpty {
                    Text.note2(partialTranscript)
                        .italic()
                        .lineLimit(2)
                        .transition(.opacity)
                }
                composer
            }
        }
        .padding(.horizontal, .layer5)
        .padding(.bottom, .layer4)
        .background {
            // The stream scrolls UNDER this bar — safeAreaInset only insets
            // the page's RESTING position, so a near-transparent backing let
            // live text run straight through the composer. Opaque paper,
            // with a short fade at the top edge so a rising line dissolves
            // into the bar instead of colliding with it.
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [Paper.page.opacity(0), Paper.page],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: .layer5)
                Paper.page
            }
            .ignoresSafeArea()
        }
    }

    // MARK: - Mic

    private var micButton: some View {
        Button {
            onMicToggle()
        } label: {
            Label(
                isSessionActive ? "Stop" : "Begin listening",
                systemImage: isSessionActive ? "mic.slash" : "mic"
            )
        }
        .buttonStyle(.mary)
        .disabled(!isMicEnabled)
        .opacity(isMicEnabled ? 1 : 0.5)
    }



    // MARK: - State chip

    private var stateChip: some View {
        HStack(spacing: .layer2) {
            StatusDot(color: chipColor)
            SectionLabel(chipText)
        }
        .help(phase == .idle && isStandingBy ? "Say \u{201C}Hey Mary\u{201D} to begin." : "")
    }

    private var chipText: String {
        switch phase {
        case .idle: return isStandingBy ? "standing by" : "resting"
        case .listening: return "listening"
        case .hearingYou: return "hearing you"
        case .transcribing: return "reading it back"
        case .thinking: return "thinking"
        case .amending: return "revising"
        case .speaking: return "speaking"
        }
    }

    private var chipColor: Color {
        switch phase {
        case .idle: return Paper.graphite.opacity(0.5)
        case .listening, .hearingYou, .amending: return .maryGold
        case .transcribing, .thinking: return .maryInk
        case .speaking: return .maryGreen
        }
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(spacing: .layer3) {
            TextField("or type to Mary…", text: $draft)
                .textFieldStyle(.plain)
                .font(.marySerif(14, italic: true))
                .focused($composerFocused)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.maryGold))
            }
            .buttonStyle(.plain)
            .disabled(!isSendEnabled || draft.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(isSendEnabled ? 1 : 0.4)
        }
        .padding(.horizontal, .layer3)
        .padding(.vertical, .layer2)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.maryFill)
        )
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSendEnabled, !text.isEmpty else { return }
        draft = ""
        onSend(text)
    }
}

/// A 24-bar mini waveform driven by the mic RMS level.
struct LevelMeter: View {
    let level: Float
    private let barCount = 24

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.maryGold.opacity(0.7))
                    .frame(width: 2, height: barHeight(index))
            }
        }
        .frame(height: 18)
        .animation(.linear(duration: 0.08), value: level)
    }

    private func barHeight(_ index: Int) -> CGFloat {
        // A gentle arch shape scaled by the level, so silence reads as a
        // hairline and speech breathes.
        let position = Double(index) / Double(barCount - 1)
        let arch = sin(position * .pi)
        let scaled = Double(min(max(level * 14, 0), 1)) * arch
        return CGFloat(2 + scaled * 16)
    }
}
