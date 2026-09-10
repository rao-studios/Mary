import AppKit
import SwiftUI

/// A floating card surface in the warm design language.
struct MaryCard<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.maryCard)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .strokeBorder(Color.maryBorder, lineWidth: 1))
            )
            .shadow(color: Color.maryInk.opacity(0.06), radius: 5, y: 2)
    }
}

/// Small uppercase section label.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.marySans(10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Color.maryInk.opacity(0.45))
    }
}

/// Gold primary-action button style.
struct MaryButtonStyle: ButtonStyle {
    var prominent: Bool = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.marySans(13, weight: .medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .foregroundStyle(prominent ? Color.white : Color.maryInk)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(prominent ? Color.maryGold : Color.maryFill)
                    .opacity(configuration.isPressed ? 0.8 : 1)
            )
            .shadow(
                color: prominent ? Color.maryGold.opacity(0.30) : .clear,
                radius: 4, y: 2)
    }
}

extension ButtonStyle where Self == MaryButtonStyle {
    static var mary: MaryButtonStyle { MaryButtonStyle(prominent: true) }
    static var maryQuiet: MaryButtonStyle { MaryButtonStyle(prominent: false) }
}

/// One-line label chip that cannot squish (`lineLimit(1)` + `fixedSize`). Pair with FlowLayout.
struct MaryChip: View {
    let label: String
    var isOn: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.maryMono(10))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(isOn ? Paper.page : Paper.ink.opacity(0.7))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isOn ? Paper.ink.opacity(0.82) : Color.maryInk.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }
}

/// Uppercase capsule tag — family, kind, LIVE, YOURS. Same anti-squish pair
/// as MaryChip (see the comment there): one line, intrinsic width, immune
/// to whatever container it lands in.
struct MaryBadge: View {
    let text: String
    var color: Color = .maryGold

    var body: some View {
        Text(text.uppercased())
            .font(.marySans(8, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(color)
            .padding(.horizontal, .layer1)
            .padding(.vertical, 1)
            .background(Capsule().strokeBorder(color.opacity(0.45), lineWidth: 1))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}

/// Value-over-label stat tile for summary rows.
struct MaryStat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.marySerif(14, weight: .medium))
                .foregroundStyle(Color.maryInk)
            Text(label)
                .font(.marySans(9))
                .foregroundStyle(Color.maryInk.opacity(0.5))
        }
        // Tile width is its content; FlowLayout wraps whole tiles.
        .lineLimit(1)
        .fixedSize()
    }
}

/// A bare "…" menu for chrome that folds at a narrow width — one more
/// header icon that happens to hide the rest of them.
struct MaryOverflowMenu<MenuContent: View>: View {
    var help: String = "More"
    @ViewBuilder var content: MenuContent

    var body: some View {
        Menu {
            content
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 14))
                .foregroundStyle(Paper.ink.opacity(0.7))
                .frame(width: 26, height: 26)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Colored status dot.
struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }
}

/// Empty-state hero with the Mary emblem.
struct EmptyHero: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(spacing: 16) {
            MaryEmblem(iconSize: 56)
            Text(title)
                .font(.marySerif(20, weight: .light, italic: true))
                .foregroundStyle(Color.maryInk)
            Text(subtitle)
                .font(.marySans(12))
                .foregroundStyle(Color.maryInk.opacity(0.45))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Open a file picker and return the chosen files.
enum FilePicker {
    static func pickFiles() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        return panel.runModal() == .OK ? panel.urls : []
    }
}
