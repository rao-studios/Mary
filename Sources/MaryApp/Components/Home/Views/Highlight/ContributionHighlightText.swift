//
//  ContributionHighlightText.swift
//  Mary
//
//  WHAT: Assistant text with per-owner brushstrokes under credited spans.
//  IN:   ContributionSpans. OUT: ContributionInspectorSheet (tap)
//

import MaryBrain
import SwiftUI

// MARK: - Paragraph highlight view

private struct ParagraphHighlightView: View {
    let text: String
    let spans: [ContributionTextSpan]
    let onTapOwner: (SewnContribution.Owner) -> Void

    @State private var tokenFrames: [TokenFrame] = []

    private struct WordToken: Identifiable {
        let id: Int
        let word: String
        let span: ContributionTextSpan?
        var isBold: Bool = false
        var isCode: Bool = false
    }

    private var tokens: [WordToken] {
        guard let attributed = text.attributed else { return rawTokens() }

        // Normalize single \n to space so they flow inline rather than
        // getting embedded inside a word token and stacking in FlowLayout.
        let cleanText = String(attributed.characters).replacingOccurrences(of: "\n", with: " ")
        let rawChars = Array(text)
        let cleanChars = Array(cleanText)

        // Map raw grapheme-cluster offset → clean grapheme-cluster offset.
        // Markdown markers (**, `, etc.) exist in raw but not in clean; they
        // get skipped so subsequent clean offsets stay correct.
        var rawToClean = [Int](repeating: 0, count: rawChars.count + 1)
        var ci = 0
        for (ri, rc) in rawChars.enumerated() {
            rawToClean[ri] = ci
            if ci < cleanChars.count && rc == cleanChars[ci] { ci += 1 }
        }
        rawToClean[rawChars.count] = ci

        // Convert span ranges (raw String.Index) to clean integer offset ranges.
        let cleanSpans: [(ContributionTextSpan, Range<Int>)] = spans.compactMap { span in
            let lo = text.distance(from: text.startIndex, to: span.range.lowerBound)
            let hi = text.distance(from: text.startIndex, to: span.range.upperBound)
            guard lo <= rawChars.count, hi <= rawChars.count else { return nil }
            let clo = rawToClean[lo], chi = rawToClean[hi]
            guard clo < chi else { return nil }
            return (span, clo..<chi)
        }

        // Tokenize the clean (marker-stripped) text by spaces. Each non-last
        // word carries its trailing space so Text("word ").kerning(0.3)
        // measures identically to the same slice inside a longer Text.
        var result: [WordToken] = []
        var tokenIdx = 0
        var cleanOffset = 0
        let components = cleanText.components(separatedBy: " ")

        for (i, word) in components.enumerated() {
            let isLast = i == components.count - 1
            let wordEnd = cleanOffset + word.count
            if !word.isEmpty {
                let match = cleanSpans.first {
                    $0.1.lowerBound < wordEnd && $0.1.upperBound > cleanOffset
                }?.0
                let (bold, code) = inlineStyle(at: cleanOffset, length: word.count, in: attributed)
                let displayWord = isLast ? word : word + " "
                result.append(WordToken(id: tokenIdx, word: displayWord, span: match, isBold: bold, isCode: code))
                tokenIdx += 1
            }
            cleanOffset = wordEnd + (isLast ? 0 : 1)
        }
        return result
    }

    /// Fallback when `AttributedString` parsing fails — no markdown styling.
    private func rawTokens() -> [WordToken] {
        var result: [WordToken] = []
        var tokenIdx = 0
        var charIdx = text.startIndex
        let normalizedText = text.replacingOccurrences(of: "\n", with: " ")
        let components = normalizedText.components(separatedBy: " ")
        for (i, word) in components.enumerated() {
            let isLast = i == components.count - 1
            let wordEnd = text.index(charIdx, offsetBy: word.count, limitedBy: text.endIndex) ?? text.endIndex
            if !word.isEmpty {
                let match = spans.first { $0.range.overlaps(charIdx..<wordEnd) }
                let displayWord = isLast ? word : word + " "
                result.append(WordToken(id: tokenIdx, word: displayWord, span: match))
                tokenIdx += 1
            }
            charIdx = wordEnd
            if !isLast, charIdx < text.endIndex {
                charIdx = text.index(after: charIdx)
            }
        }
        return result
    }

    /// Checks `InlinePresentationIntent` attributes in the given character range.
    private func inlineStyle(
        at offset: Int, length: Int, in attributed: AttributedString
    ) -> (isBold: Bool, isCode: Bool) {
        guard length > 0 else { return (false, false) }
        let start = attributed.index(attributed.startIndex, offsetByCharacters: offset)
        guard start < attributed.endIndex else { return (false, false) }
        let rawEnd = attributed.index(start, offsetByCharacters: length)
        let end = rawEnd > attributed.endIndex ? attributed.endIndex : rawEnd
        guard start < end else { return (false, false) }
        var bold = false, code = false
        for run in attributed[start..<end].runs {
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) { bold = true }
                if intent.contains(.code) { code = true }
            }
        }
        return (bold, code)
    }

    var body: some View {
        FlowLayout(spacing: 0, lineSpacing: 7) {
            ForEach(tokens) { token in
                Text(token.word)
                    .foregroundStyle(Color.primary.opacity(0.75))
                    .font(token.isCode
                          ? .system(size: 15, weight: .regular, design: .monospaced)
                          : .system(size: 18, weight: token.isBold ? .semibold : .light, design: .serif))
                    .italic(!token.isCode)
                    .kerning(token.isCode ? 0 : 0.3)
                    .background(frameCapture(for: token))
            }
        }
        .coordinateSpace(name: "maryFlow")
        .onPreferenceChange(TokenFrameKey.self) { frames in
            tokenFrames = frames
        }
        .overlay {
            let segments = lineSegments(from: tokenFrames)
            ForEach(Array(segments.enumerated()), id: \.element.id) { idx, segment in
                BrushStrokeSegment(
                    segment: segment,
                    delay: Double(idx) * 0.15,
                    onTap: { onTapOwner(segment.owner) }
                )
            }
        }
    }

    @ViewBuilder
    private func frameCapture(for token: WordToken) -> some View {
        if let span = token.span,
           !token.word.trimmingCharacters(in: .whitespaces).isEmpty {
            GeometryReader { geo in
                Color.clear
                    .preference(
                        key: TokenFrameKey.self,
                        value: [TokenFrame(
                            spanID: span.id,
                            frame: geo.frame(in: .named("maryFlow")),
                            color: span.color,
                            owner: span.owner
                        )]
                    )
            }
        }
    }

    private func lineSegments(from frames: [TokenFrame]) -> [LineSegment] {
        var bySpan: [String: [TokenFrame]] = [:]
        for frame in frames { bySpan[frame.spanID, default: []].append(frame) }

        var segments: [LineSegment] = []
        // Sorted so stagger delays stay stable across body passes.
        for spanID in bySpan.keys.sorted() {
            guard let spanFrames = bySpan[spanID] else { continue }
            guard let first = spanFrames.first else { continue }

            let sorted = spanFrames.sorted {
                abs($0.frame.minY - $1.frame.minY) < 4
                    ? $0.frame.minX < $1.frame.minX
                    : $0.frame.minY < $1.frame.minY
            }

            // Group into per-line buckets (4 pt Y tolerance)
            var lineGroups: [[TokenFrame]] = [[]]
            for frame in sorted {
                let lineY = lineGroups.last?.first?.frame.minY ?? frame.frame.minY
                if abs(frame.frame.minY - lineY) < 4 {
                    lineGroups[lineGroups.count - 1].append(frame)
                } else {
                    lineGroups.append([frame])
                }
            }

            for (lineIdx, line) in lineGroups.enumerated() where !line.isEmpty {
                let minX = line.map(\.frame.minX).min()!
                let maxX = line.map(\.frame.maxX).max()!
                let minY = line.map(\.frame.minY).min()!
                let maxY = line.map(\.frame.maxY).max()!
                segments.append(LineSegment(
                    id: "\(spanID)-\(lineIdx)",
                    spanID: spanID,
                    frame: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
                    color: first.color,
                    owner: first.owner,
                    seed: StableHash.of(spanID) ^ lineIdx
                ))
            }
        }
        // Reading order, so the stagger sweeps down the paragraph the way a
        // hand would draw it — and, more importantly, so it is the SAME sweep
        // every render regardless of what order the frames arrived in.
        return segments.sorted {
            abs($0.frame.minY - $1.frame.minY) < 4
                ? $0.frame.minX < $1.frame.minX
                : $0.frame.minY < $1.frame.minY
        }
    }
}

// MARK: - Contribution highlight text (paragraph splitter)

struct ContributionHighlightText: View {
    let text: String
    let spans: [ContributionTextSpan]
    let onTapOwner: (SewnContribution.Owner) -> Void

    private struct ParagraphItem: Identifiable {
        let id: Int
        let text: String
        let localSpans: [ContributionTextSpan]
    }

    private var paragraphItems: [ParagraphItem] {
        var items: [ParagraphItem] = []
        var cursor = text.startIndex
        var index = 0

        while cursor < text.endIndex {
            let separatorRange = text.range(of: "\n\n", range: cursor..<text.endIndex)
            let paragraphEnd = separatorRange?.lowerBound ?? text.endIndex
            let paragraphRange = cursor..<paragraphEnd
            let paragraphText = String(text[paragraphRange])

            let localSpans: [ContributionTextSpan] = spans.compactMap { span in
                guard span.range.overlaps(paragraphRange) else { return nil }
                let clampedLower = max(span.range.lowerBound, paragraphRange.lowerBound)
                let clampedUpper = min(span.range.upperBound, paragraphRange.upperBound)
                guard clampedLower < clampedUpper else { return nil }
                let localLower = text.distance(from: cursor, to: clampedLower)
                let localUpper = text.distance(from: cursor, to: clampedUpper)
                guard localLower >= 0, localUpper <= paragraphText.count,
                      localLower < localUpper else { return nil }
                let pStart = paragraphText.index(
                    paragraphText.startIndex, offsetBy: localLower,
                    limitedBy: paragraphText.endIndex) ?? paragraphText.endIndex
                let pEnd = paragraphText.index(
                    paragraphText.startIndex, offsetBy: localUpper,
                    limitedBy: paragraphText.endIndex) ?? paragraphText.endIndex
                guard pStart < pEnd else { return nil }
                return ContributionTextSpan(
                    range: pStart..<pEnd, in: paragraphText,
                    owner: span.owner, color: span.color)
            }

            items.append(ParagraphItem(id: index, text: paragraphText, localSpans: localSpans))
            index += 1
            cursor = separatorRange?.upperBound ?? text.endIndex
        }

        return items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(paragraphItems) { item in
                ParagraphHighlightView(
                    text: item.text,
                    spans: item.localSpans,
                    onTapOwner: onTapOwner
                )
            }
        }
    }
}

// MARK: - Brushstroke segment (animated)

private struct BrushStrokeSegment: View {
    let segment: LineSegment
    let delay: Double
    let onTap: () -> Void

    @State private var opacity: Double = 0

    var body: some View {
        BrushStroke(seed: segment.seed)
            .fill(segment.color.opacity(0.20))
            .frame(width: segment.frame.width + 12, height: segment.frame.height + 8)
            .position(x: segment.frame.midX, y: segment.frame.midY)
            .opacity(opacity)
            .animation(.easeIn(duration: 0.7).delay(delay), value: opacity)
            .onTapGesture { onTap() }
            .onAppear { opacity = 1 }
    }
}

// MARK: - Supporting types

private struct TokenFrame: Equatable {
    let spanID: String
    let frame: CGRect
    let color: Color
    let owner: SewnContribution.Owner

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.spanID == rhs.spanID && lhs.frame == rhs.frame
    }
}

private struct TokenFrameKey: PreferenceKey {
    static var defaultValue: [TokenFrame] = []
    static func reduce(value: inout [TokenFrame], nextValue: () -> [TokenFrame]) {
        value.append(contentsOf: nextValue())
    }
}

private struct LineSegment: Identifiable {
    let id: String
    let spanID: String
    let frame: CGRect
    let color: Color
    let owner: SewnContribution.Owner
    let seed: Int
}
