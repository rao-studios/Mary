//
//  VoiceStatusBar.swift
//  Mary
//
//  WHAT: Floating bar — mic, phase chip, level meter, typed composer.
//  IN:   VoiceBar (Home+View)
//  OUT:  ChatService / VoiceService via callbacks
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
    /// Detached routines still running — pill names them and can stop one.
    var runningRoutines: [RunningRoutineRow] = []
    /// "Hey Mary" standby (wake enabled + ready + session off). Not a header tint.
    var isStandingBy: Bool = false
    /// Arm / disarm. Watching ⇄ speaking while armed.
    let onMicToggle: () -> Void
    let onSend: (String) -> Void

    @State private var draft: String = ""
    @State private var showingRunning = false
    @FocusState private var composerFocused: Bool

    var body: some View {
        MaryCard(padding: 14) {
            VStack(alignment: .leading, spacing: .layer3) {
                HStack(spacing: .layer4) {
                    micButton
                    HStack(spacing: .layer2) {
                    }
                    stateChip
                    if !runningRoutines.isEmpty {
                        runningPill
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
            // Opaque paper: stream scrolls under this bar (safeAreaInset only insets rest).
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

    // MARK: - Running work

    /// Running-work pill. Popover lists what is running and can stop one (or all).
    private var runningPill: some View {
        Button {
            showingRunning.toggle()
        } label: {
            HStack(spacing: .layer2) {
                StatusDot(color: .maryGold)
                SectionLabel(runningRoutines.count == 1
                    ? "still working"
                    : "\(runningRoutines.count) running")
            }
        }
        .buttonStyle(.plain)
        .help("What Mary is still working on — and how to stop it")
        .popover(isPresented: $showingRunning, arrowEdge: .top) {
            runningList
        }
    }

    private var runningList: some View {
        VStack(alignment: .leading, spacing: .layer3) {
            HStack {
                SectionLabel("still working")
                Spacer()
                if runningRoutines.count > 1 {
                    Button("Stop all") {
                        RunControl.stopAll()
                        showingRunning = false
                    }
                    .buttonStyle(.maryQuiet)
                }
            }
            ForEach(runningRoutines) { row in
                HStack(spacing: .layer3) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.label.isEmpty ? "background work" : row.label)
                            .font(.marySans(12))
                            .foregroundStyle(Color.primary.opacity(0.8))
                            .lineLimit(2)
                        Text(row.elapsed)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.primary.opacity(0.45))
                    }
                    Spacer(minLength: .layer3)
                    // Ordinary correction, not a destructive confirm.
                    Button("Stop") { RunControl.stopRoutine(id: row.id) }
                        .buttonStyle(.maryQuiet)
                }
            }
        }
        .padding(.layer4)
        .frame(minWidth: 260, maxWidth: 340)
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

/// A 24-bar mini waveform driven by mic RMS.
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
        // Arch scaled by level: silence is a hairline, speech breathes.
        let position = Double(index) / Double(barCount - 1)
        let arch = sin(position * .pi)
        let scaled = Double(min(max(level * 14, 0), 1)) * arch
        return CGFloat(2 + scaled * 16)
    }
}
