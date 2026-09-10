//
//  AbilityRowView.swift
//  Mary
//
//  WHAT: One ability, as a row: artwork, name, who made it, what it extends.
//  IN:   Ability Studio rail; any later gallery or picker.
//  OUT:  AbilityParadigmPresentation vocabulary + Color.maryAbilityTint.
//  PIN:  Artwork is generated from the ability's own tint and role glyph. A
//        package carries no image, and inventing one per ability would be a
//        second source of truth about what an ability is.
//

import MaryFoundation
import SwiftUI

// MARK: - Artwork

/// The tinted tile that stands in for an ability. Same gradient recipe at every
/// size, so a row and a gallery card read as the same object.
struct AbilityArtwork: View {
    let tint: Color
    let symbol: String
    var side: CGFloat = 44

    private var radius: CGFloat { side * 0.28 }

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [tint.opacity(0.62), tint.opacity(0.24)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing))
            .overlay(
                // A soft highlight where the light would fall, so the tile has
                // depth without a drop shadow doing the work.
                RadialGradient(
                    colors: [Color.white.opacity(0.55), .clear],
                    center: .init(x: 0.25, y: 0.2),
                    startRadius: 0,
                    endRadius: side * 0.75))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.45), lineWidth: 0.5))
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: side * 0.38, weight: .light))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .shadow(color: tint.opacity(0.45), radius: 1, y: 0.5))
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

// MARK: - Lineage badge

/// What an ability belongs to: the discipline an expertise realizes, or its own
/// role when it realizes nothing.
struct AbilityLineageBadge: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 7, weight: .semibold))
            Text(text)
                .font(.marySans(9, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.13)))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - Row

/// One ability in a list. `trailing` is where a price, a state chip, or an
/// install button goes; the row itself stays about identity.
struct AbilityRowView<Trailing: View>: View {

    enum Size {
        /// Sidebars and pickers.
        case compact
        /// Galleries, where an ability is the subject rather than a choice.
        case large

        var artwork: CGFloat { self == .compact ? 44 : 64 }
        var titleSize: CGFloat { self == .compact ? 12.5 : 15 }
        var spacing: CGFloat { self == .compact ? 10 : 14 }
    }

    let package: MaryAbilityPackage
    var size: Size = .compact
    var isSelected: Bool = false
    @ViewBuilder var trailing: Trailing

    private var tint: Color { Color.maryAbilityTint(package.ability.tint) }
    private var presentation: AbilityParadigmPresentation {
        AbilityParadigmPresentation(package.paradigm)
    }

    var body: some View {
        HStack(alignment: .center, spacing: size.spacing) {
            AbilityArtwork(
                tint: tint,
                symbol: presentation.symbol,
                side: size.artwork)

            VStack(alignment: .leading, spacing: 2) {
                Text(package.ability.title)
                    .font(.marySans(size.titleSize, weight: .semibold))
                    .foregroundStyle(Color.maryInk)
                    .lineLimit(size == .compact ? 1 : 2)
                    .multilineTextAlignment(.leading)

                Text(byline)
                    .font(.marySans(size == .compact ? 10 : 11))
                    .foregroundStyle(Color.maryInk.opacity(0.42))
                    .lineLimit(1)

                AbilityLineageBadge(
                    text: lineageText,
                    symbol: lineageSymbol,
                    tint: lineageTint)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing
        }
        .padding(.horizontal, size == .compact ? 8 : 14)
        .padding(.vertical, size == .compact ? 7 : 12)
        .background(
            RoundedRectangle(cornerRadius: size == .compact ? 10 : 16, style: .continuous)
                .fill(isSelected ? Color.maryFill : .clear))
        .overlay(
            RoundedRectangle(cornerRadius: size == .compact ? 10 : 16, style: .continuous)
                .strokeBorder(Paper.highlight, lineWidth: 2)
                .opacity(isSelected ? 1 : 0))
        .contentShape(Rectangle())
    }

    // MARK: - Copy

    /// `local` is what the Studio stamps on a package you saved yourself.
    private var byline: String {
        let publisher = package.package.publisher
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if publisher.isEmpty { return "by someone" }
        if publisher.lowercased() == "local" { return "by you" }
        return publisher.hasPrefix("@") ? "by \(publisher)" : "by \(publisher)"
    }

    /// An expertise belongs to the craft it realizes; everything else belongs
    /// to its own role. One word either way — the badge sits in a sidebar, and
    /// "application expertise" only ever arrives truncated.
    private var lineageText: String {
        if let discipline = package.extendedDisciplines.first {
            return discipline.rawValue
        }
        switch package.paradigm {
        case .discipline: return "discipline"
        case .applicationExpertise: return "expertise"
        case .systemControl: return "system"
        case .reasoning: return "reasoning"
        }
    }

    private var lineageSymbol: String {
        package.extendedDisciplines.isEmpty
            ? presentation.symbol
            : AbilityParadigmPresentation(.discipline).symbol
    }

    private var lineageTint: Color {
        // A realized discipline keeps this ability's tint rather than the
        // discipline's: the badge says what this one belongs to, not who owns it.
        tint
    }
}

extension AbilityRowView where Trailing == EmptyView {
    init(
        package: MaryAbilityPackage,
        size: Size = .compact,
        isSelected: Bool = false
    ) {
        self.init(
            package: package,
            size: size,
            isSelected: isSelected,
            trailing: { EmptyView() })
    }
}
