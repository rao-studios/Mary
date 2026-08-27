//
//  DebuggerPaneView+Sections.swift
//

import MaryBrain
import SwiftUI
import MaryRuntime

extension DebuggerPaneView {

    // MARK: - Filter bar

    /// Eyes first, then All, then one chip per running app in the sweep's own
    /// watched-first order — so the apps Mary actually has eyes for are
    /// always the leftmost thing the user reaches for.
    var filterBar: some View {
        let tabs = WindowTileBuilder.filterTabs(
            vm.model.groups, selected: filter.uncappedGroupID)
        return VStack(alignment: .leading, spacing: .layer2) {
            LazyVGrid(columns: tabGrid, alignment: .leading, spacing: .layer1) {
                chip(
                    isSelected: filter == .eyes,
                    dot: eyesDot,
                    help: "Eyes — only the applications an installed Ability teaches her to watch.",
                    icon: { Image(systemName: "eye").font(.system(size: 12)) },
                    action: { select(.eyes) })
                chip(
                    isSelected: filter == .all,
                    dot: nil,
                    help: "All — every window on every Space.",
                    icon: { Image(systemName: "square.grid.2x2").font(.system(size: 11)) },
                    action: { select(.all) })
                ForEach(tabs.tabs) { group in
                    appChip(group)
                }
                if tabs.hidden > 0 {
                    // The bar's own overflow — never silently dropped, same
                    // doctrine as a group's "+N more".
                    Text("+\(tabs.hidden)")
                        .font(.marySans(10, weight: .medium))
                        .foregroundStyle(Color.maryInk.opacity(0.45))
                        .frame(width: 20, height: 20)
                        .padding(3)
                        .help("\(tabs.hidden) more apps than the bar shows as tabs — they're all still in the All list.")
                }
            }
            HStack(spacing: .layer2) {
                Text(selectionLabel)
                    .font(.marySans(10))
                    .foregroundStyle(Paper.graphite)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: .layer1)
                scopeToggle
            }
        }
        .padding(.horizontal, .layer4)
        .padding(.vertical, .layer2)
        // Opaque: tiles scroll UNDER the inset, and a translucent bar over
        // moving thumbnails is unreadable.
        .background(Paper.page)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.maryBorder).frame(height: 1)
        }
    }

    /// One tab chip. Selected = the filled `Paper.highlight` capsule (the
    /// FOCUS badge below, verbatim); unselected = the outlined-gold capsule
    /// the inspector's PINNED badge uses. NEVER `.maryQuiet` — its 16 pt
    /// horizontal padding overflows the ~268 pt floor after three chips.
    func chip<Icon: View>(
        isSelected: Bool,
        dot: Color?,
        help: String,
        @ViewBuilder icon: () -> Icon,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            icon()
                .foregroundStyle(isSelected ? Paper.ink.opacity(0.75) : Color.maryGold)
                .frame(width: 20, height: 20)
                .padding(3)
                .background {
                    if isSelected {
                        Capsule().fill(Paper.highlight.opacity(0.6))
                    } else {
                        Capsule().strokeBorder(Color.maryGold.opacity(0.45), lineWidth: 1)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let dot {
                        // The token at its native 8 pt would eat a third of a
                        // 26 pt chip — scaled, never re-invented, so the pane
                        // keeps ONE dot vocabulary.
                        StatusDot(color: dot).scaleEffect(0.7).offset(x: 1, y: 1)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(help)
    }

    func appChip(_ group: AppTileGroup) -> some View {
        chip(
            isSelected: filter == .app(group.id),
            dot: dotColor(for: group),
            help: chipHelp(group),
            icon: {
                Group {
                    if let icon = vm.icon(forPID: group.pid) {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        // No icon (dev binaries, agent-launched processes) —
                        // the initial keeps the chip identifiable, not blank.
                        Text(group.appName.prefix(1).uppercased())
                            .font(.marySans(11, weight: .semibold))
                    }
                }
            },
            action: { select(.app(group.id)) })
    }

    /// The capture-scope toggle the user asked for: capture everything, or
    /// only what's filtered.
    var scopeToggle: some View {
        let isFiltered = captureScope == .filtered
        return Button {
            captureScopeToken = (isFiltered ? CaptureScope.all : .filtered).rawValue
        } label: {
            HStack(spacing: 3) {
                Image(systemName: isFiltered ? "camera.aperture" : "camera.on.rectangle")
                    .font(.system(size: 8))
                Text(isFiltered ? "FILTERED" : "ALL")
                    .font(.marySans(9, weight: .semibold))
                    .tracking(0.6)
            }
            .padding(.horizontal, .layer2)
            .padding(.vertical, 2)
            .foregroundStyle(isFiltered ? Paper.ink.opacity(0.75) : Color.maryGold)
            .background {
                if isFiltered {
                    Capsule().fill(Paper.highlight.opacity(0.6))
                } else {
                    Capsule().strokeBorder(Color.maryGold.opacity(0.45), lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        // The tradeoff, stated plainly — it is a real one either way.
        .help(filter == .all
            ? "Capture scope — pick a tab first; with All selected there is nothing to narrow."
            : "Capture scope. ALL keeps every window warm, so switching tabs shows current thumbnails instantly. FILTERED spends the whole six-shots-a-second budget on the tab in view, so it refreshes several times faster while the others go stale.")
        .disabled(filter == .all)
        .opacity(filter == .all ? 0.45 : 1)
    }

    /// The selected tab's NAME, on its own line rather than inside the chip:
    /// an `.adaptive(minimum: 28)` grid hands every item the same column
    /// width, so a variable-width selected chip would overrun its neighbours.
    /// The unselected chips carry their names in `.help()` instead.
    var selectionLabel: String {
        switch filter {
        case .all:
            return "All apps"
        case .eyes:
            let names = visibleGroups.map(\.appName)
            return names.isEmpty
                ? "Eyes — nothing Mary watches is running"
                : "Eyes — \(names.joined(separator: ", "))"
        case .app(let id):
            return vm.model.groups.first { $0.id == id }?.appName ?? "Filtered"
        }
    }

    func select(_ next: EyesFilter) {
        filterToken = next.token
    }

    /// Watched-and-seeing vs blind, read off the same PerceptionCards the
    /// captions use, with the SAME rule as the inspector header's dot — the
    /// bar and the drill-in must never tell different stories about one app.
    /// Unwatched apps get no dot: Mary has no claim to make about them.
    func dotColor(for group: AppTileGroup) -> Color? {
        guard let card = card(for: group.bundleID) else { return nil }
        return card.blindness == nil ? .maryGreen : .maryError
    }

    /// The Eyes tab aggregates: green while at least one watched world is
    /// seeing clearly, red when every one of them is blind.
    var eyesDot: Color {
        perceptionVM.cards.contains { $0.blindness == nil } ? .maryGreen : .maryError
    }

    func chipHelp(_ group: AppTileGroup) -> String {
        let windows = group.windows.count + group.overflowCount
        var help = "\(group.appName) — \(windows) window\(windows == 1 ? "" : "s")"
        if let card = card(for: group.bundleID) {
            help += card.blindness.map { " — \($0.label)" } ?? " — seeing"
        }
        return help
    }

    func card(for bundleID: String?) -> PerceptionCard? {
        guard let world = PerceptionSnapshotViewModel.world(forBundleID: bundleID) else {
            return nil
        }
        return perceptionVM.cards.first { $0.world == world }
    }

    /// An honest empty state beats a silent fallback: the Eyes tab with
    /// nothing watched running IS an answer ("Mary sees nothing right
    /// now"). Only a filter whose app LEFT the sweep falls back to All.
    var emptyFilterNote: some View {
        MaryCard(padding: 12) {
            Text(filter == .eyes
                ? "None of Mary's watched applications are running — open one an Ability covers, or switch to All."
                : "Nothing to show under this filter — switch to All.")
                .font(.marySans(11))
                .foregroundStyle(Color.maryInk.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Groups

    func groupSection(_ group: AppTileGroup) -> some View {
        let world = PerceptionSnapshotViewModel.world(forBundleID: group.bundleID)
        let card = world.flatMap { world in
            perceptionVM.cards.first { $0.world == world }
        }
        let isEffective = world.map { perceptionVM.focus.isEffective($0) } ?? false
        return VStack(alignment: .leading, spacing: .layer2) {
            HStack(spacing: .layer2) {
                SectionLabel(group.appName)
                if isEffective {
                    Text("FOCUS")
                        .font(.marySans(9, weight: .semibold))
                        .tracking(0.8)
                        .padding(.horizontal, .layer1)
                        .padding(.vertical, 1)
                        .background(Paper.highlight.opacity(0.6), in: Capsule())
                        .foregroundStyle(Paper.ink.opacity(0.7))
                }
                if isPinned(group) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.maryGold)
                }
            }
            LazyVGrid(columns: grid, alignment: .leading, spacing: .layer3) {
                ForEach(group.windows) { tile in
                    tileView(tile, card: card, isEffective: isEffective)
                }
            }
            if group.overflowCount > 0 {
                Text("+\(group.overflowCount) more")
                    .font(.marySans(10))
                    .foregroundStyle(Color.maryInk.opacity(0.45))
            }
        }
    }

    // MARK: - Tiles

    func tileView(_ tile: WindowTile, card: PerceptionCard?, isEffective: Bool) -> some View {
        VStack(alignment: .leading, spacing: .layer1) {
            ZStack(alignment: .topTrailing) {
                thumbnailView(tile)
                if !tile.isOnActiveSpace {
                    Text("other space")
                        .font(.marySans(9, weight: .medium))
                        .padding(.horizontal, .layer1)
                        .padding(.vertical, 1)
                        .background(Color.maryInk.opacity(0.55), in: Capsule())
                        .foregroundStyle(Color.white)
                        .padding(.layer1)
                }
            }
            captionStrip(card, windowID: tile.id)
        }
        .padding(.layer1)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selectedWindowID == tile.id ? Color.maryFill : Color.clear))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isEffective ? Paper.highlight : Color.maryBorder,
                    lineWidth: isEffective ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture {
            selectedWindowID = tile.id
            // A recognized card opens its inspector. Keynote is recognizable
            // but unavailable and renders that state without a pin; wholly
            // unknown apps still take the not-pinnable branch.
            selectedWorld = PerceptionSnapshotViewModel
                .world(forBundleID: tile.bundleID)?.rawValue
        }
        // Scroll visibility feeds the capture stagger — visible tiles
        // refresh every 1–2 s, off-screen ones rotate through the budget.
        .onAppear { vm.tileAppeared(tile.id) }
        .onDisappear { vm.tileDisappeared(tile.id) }
    }

    @ViewBuilder
    func thumbnailView(_ tile: WindowTile) -> some View {
        if let cgImage = tile.thumbnail {
            Image(decorative: cgImage, scale: 2)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            // Icon card — degraded mode, or a window whose capture hasn't
            // landed (minimized, close race), or one that photographed as
            // NOTHING. That last case used to render exactly like the others
            // (and, when the blank image was stored, as a featureless white
            // rectangle): the ghost the user reported was a successful
            // capture of a window with no backing store, and the pane said
            // the same thing it says about a window it simply hasn't reached
            // yet. It says which now.
            HStack(spacing: .layer2) {
                if let icon = vm.icon(forPID: tile.pid) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 28, height: 28)
                }
                VStack(alignment: .leading, spacing: 1) {
                    // RAW title, never coalesced to the app name here either
                    // — an untitled window wearing "Pages" is the mask that
                    // hid the hypothesis.
                    Text(tile.title ?? tile.appName)
                        .font(.marySans(11))
                        .foregroundStyle(Color.maryInk.opacity(0.65))
                        .lineLimit(2)
                    if let note = captureNote(tile.captureState) {
                        Text(note)
                            .font(.marySans(9))
                            .foregroundStyle(Color.maryError.opacity(0.8))
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.layer2)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(Color.maryFill, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    /// Only the states that mean something went wrong get a caption — a
    /// never-captured tile is just early.
    func captureNote(_ state: WindowCaptureState) -> String? {
        switch state {
        case .never, .captured: return nil
        case .blank(let transparent):
            return transparent ? "captured — nothing drawn" : "captured — flat fill"
        case .failed: return "capture failed"
        }
    }

    /// The truthful caption, re-derived from the PerceptionCard (first 2–3
    /// fields — the inspector shows all of them): what the watcher parsed, why
    /// it's blind, or "no eyes here" — never inferred from pixels.
    /// accessibilityLimited is PARTIAL, so its fields render.
    ///
    /// PER WINDOW, NOT PER WORLD. `card.fields(forWindow:)` answers with THIS
    /// window's fields when the world published any, and with the world's
    /// otherwise — so Xcode, Pages and Scrivener render byte for byte as
    /// before, and thirteen TextEdit notes stop all being captioned with the
    /// front one's name. `tile.id` is a `CGWindowID`, which is the same
    /// integer TextEdit publishes as `id of window`; see
    /// `PerceptionCard.windowFields`.
    @ViewBuilder
    func captionStrip(_ card: PerceptionCard?, windowID: CGWindowID? = nil) -> some View {
        if let card {
            if let blindness = card.blindness, blindness != .accessibilityLimited {
                Text("\(blindness.label) — \(blindness.remedy)")
                    .font(.marySans(10))
                    .foregroundStyle(Color.maryError)
                    .lineLimit(2)
            } else {
                let shown = card.fields(forWindow: windowID.map(Int.init))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: .layer1) {
                        Text(shown.first?.value ?? "no snapshot yet")
                            .font(.marySans(10))
                            .foregroundStyle(Paper.graphite)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        if let capturedAt = card.capturedAt {
                            Text(PerceptionReport.ageString(
                                Date().timeIntervalSince(capturedAt)))
                                .font(.maryMono(9))
                                .foregroundStyle(Color.maryInk.opacity(0.4))
                        }
                    }
                    ForEach(Array(shown.dropFirst().prefix(2)), id: \.label) { field in
                        Text("\(field.label) \(field.value)")
                            .font(.marySans(9))
                            .foregroundStyle(Paper.graphite.opacity(0.75))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        } else {
            Text("Mary has no eyes here")
                .font(.marySans(10))
                .foregroundStyle(Color.maryInk.opacity(0.45))
        }
    }

}
