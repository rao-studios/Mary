//
//  StreamingUtteranceView.swift
//  Mary
//
//  The in-flight reply: three pulsing dots while the model deliberates, then
//  the Void streaming look — paragraphs revealing char-by-char with a
//  blinking " |" cursor. Ported verbatim from Gita's StreamingPassageView.
//

import SwiftUI

struct StreamingUtteranceView: View {
    let text: String
    let isThinking: Bool

    @State private var cursorVisible: Bool = true
    private let timer = Timer.publish(every: 0.55, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if isThinking {
                ThinkingDotsView()
                    .padding(.leading, .layer1)
            } else {
                customNote(text)
                    .italic()
                    .lineSpacing(7)
                    .kerning(0.3)
                    .frame(maxWidth: Paper.measure, alignment: .leading)
                    .onReceive(timer) { _ in
                        cursorVisible.toggle()
                    }
            }
        }
    }

    private func customNote(_ text: String) -> some View {
        let paragraphs = text.components(separatedBy: "\n\n")
        return VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { offset, paragraph in
                let isLast = offset == paragraphs.count - 1
                if let attributed = paragraph.attributed {
                    Text.note(attributed) + cursor(isLast: isLast)
                } else {
                    Text.note(paragraph) + cursor(isLast: isLast)
                }
            }
        }
    }

    private func cursor(isLast: Bool) -> Text {
        Text(cursorVisible && isLast ? " |" : "  ")
            .foregroundColor(Color.primary.opacity(cursorVisible && isLast ? 0.4 : 0))
    }
}

struct ThinkingDotsView: View {
    @State private var animating: Bool = false

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.primary)
                    .frame(width: 2.5, height: 2.5)
                    .opacity(animating ? 0.55 : 0.2)
                    .animation(
                        .easeInOut(duration: 2)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.35),
                        value: animating
                    )
            }
        }
        .frame(height: 24, alignment: .leading)
        .onAppear { animating = true }
    }
}
