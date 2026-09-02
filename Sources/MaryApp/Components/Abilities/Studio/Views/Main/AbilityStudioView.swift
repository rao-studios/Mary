//
//  AbilityStudioView.swift
//  Mary
//
//  WHAT: The Ability Studio — one window: abilities, then Recipe / Tune / Skills.
//  IN:   Home's shippingbox button (Window "ability-studio").
//  OUT:  AbilityStudioViewModel. Install and activation stay in AbilityLibrary.
//  PIN:  One view model for the whole window. The second editor window is gone;
//        a dirty draft is asked about, never refused.
//

import Granite
import MaryBrain
import MaryRuntime
import SwiftUI

@MainActor
struct AbilityStudioView: View {
    @StateObject var model = AbilityStudioViewModel()
    @Relay(.silence) var config: ConfigService
    @AppStorage("abilityStudio.railCollapsed") private var railCollapsed = false
    @State private var showsAdvanced = false
    @State private var showsNewPackageSheet = false
    /// Set when an issue in the drawer points at a pane; cleared on the next
    /// selection so the ring is a nudge, not a mode.
    @State private var focusedPane: AbilityStudioPane?

    var body: some View {
        HStack(spacing: 0) {
            if !railCollapsed {
                AbilityStudioRail(model: model) { showsNewPackageSheet = true }
                    .transition(.move(edge: .leading))
            }

            VStack(spacing: 0) {
                if let package = model.draftPackage {
                    AbilityStudioHeader(
                        model: model,
                        package: package,
                        railCollapsed: $railCollapsed,
                        showsAdvanced: $showsAdvanced,
                        cost: model.costEstimate,
                        pricePerCall: config.state.modelCallPriceUSD)
                    panes(package)
                } else {
                    unreadableDraft
                }
                AbilityStudioFooter(model: model) { showsAdvanced = true }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showsAdvanced, let package = model.draftPackage {
                AbilityStudioAdvancedDrawer(model: model, package: package) { pane in
                    focusedPane = pane
                }
                .transition(.move(edge: .trailing))
            }
        }
        .frame(minWidth: 1040, minHeight: 680)
        .background(Paper.page)
        .preferredColorScheme(.light)
        .animation(.easeInOut(duration: 0.16), value: railCollapsed)
        .animation(.easeInOut(duration: 0.16), value: showsAdvanced)
        .onChange(of: model.selectedPackageID) { _, _ in focusedPane = nil }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .sheet(isPresented: $showsNewPackageSheet) {
            AbilityStudioNewPackageSheet(model: model)
        }
        .confirmationDialog(
            "Save your changes to this ability?",
            isPresented: Binding(
                get: { model.pendingSelection != nil },
                set: { if !$0 { model.resolvePendingSelection(.cancel) } }),
            titleVisibility: .visible
        ) {
            Button("Save") { model.resolvePendingSelection(.save) }
                .disabled(!model.validation.isValid)
            Button("Discard", role: .destructive) { model.resolvePendingSelection(.discard) }
            Button("Keep editing", role: .cancel) { model.resolvePendingSelection(.cancel) }
        } message: {
            Text(model.validation.isValid
                 ? "Switching abilities leaves this draft behind."
                 : "This draft cannot be saved yet. Discarding loses the changes.")
        }
    }

    // MARK: - Panes

    @ViewBuilder
    private func panes(_ package: MaryAbilityPackage) -> some View {
        HStack(alignment: .top, spacing: .layer4) {
            AbilityStudioRecipePane(model: model, package: package)
                .frame(width: 420)
                .overlay(focusRing(.recipe))

            VStack(spacing: .layer3) {
                AbilityStudioTunePane(model: model, package: package)
                    .overlay(focusRing(.tune))
                AbilityStudioSkillsPane(model: model, package: package)
                    .overlay(focusRing(.skills))
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, .layer5)
        .padding(.vertical, .layer4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The drawer points here; the ring says "this one" without moving anything.
    private func focusRing(_ pane: AbilityStudioPane) -> some View {
        RoundedRectangle(cornerRadius: 18)
            .strokeBorder(Paper.highlight, lineWidth: 2)
            .opacity(focusedPane == pane ? 1 : 0)
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.2), value: focusedPane)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.marySans(11))
            .foregroundStyle(Color.maryInk.opacity(0.4))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, .layer3)
    }

    /// The draft JSON does not decode. Everything visual is off the table until
    /// it does, so say so rather than showing empty panes.
    private var unreadableDraft: some View {
        VStack(spacing: .layer3) {
            Spacer()
            EmptyHero(
                title: model.snapshot.records.isEmpty ? "No abilities yet" : "This draft cannot be opened",
                subtitle: model.snapshot.records.isEmpty
                    ? "Add a .mary package to the Abilities folder, or teach Mary an application."
                    : "The schema underneath does not parse. Repair it in Advanced, then come back.")
            HStack(spacing: .layer2) {
                Button("Teach an application") { showsNewPackageSheet = true }
                    .buttonStyle(.mary)
                Button("Import a .mary file", action: model.importPackage)
                    .buttonStyle(.maryQuiet)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.layer5)
    }
}
