//
//  WireframeStageView.swift
//  Sand
//
//  WHAT: The stage — one Canvas redrawn each time a fresh snapshot arrives.
//  IN:   WireframeViewModel (+ SandTraceModel's marks, drawn on top)
//  OUT:  the wireframe, the HUD, the ambient inspector, the breadcrumb
//  PIN:  DATA-DRIVEN, NOT A TIMELINE. A free-running TimelineView would burn
//        frames against identical data; the poller publishes only when the
//        tree changed, and this view paints whatever arrives.
//        DESKTOP-BOUNDS CONTEXT: the coordinate frame is the union of every
//        screen, not just the target's windows — so a multi-window app, and
//        where it sits on the desktop, both read correctly.
//        CLICK-TO-ZOOM: a tap resolves to the smallest window-or-element under
//        it (`AXHitTest`, over the SAME frames the renderer drew from) and
//        narrows the stage to exactly that frame. The breadcrumb is the way
//        back out.
//
import MaryComputerUse
import SwiftUI

struct WireframeStageView: View {
    @ObservedObject var model: WireframeViewModel
    @ObservedObject var trace: SandTraceModel
    @State private var showHUD = true
    /// Off by default: the wireframe is the app, and the ambient artifact is an
    /// inspection of what it would feed Mary. Its derivation is gated on this,
    /// so an unopened panel costs nothing per publish.
    @State private var showAmbient = false
    /// The reconstruction needs to know which way round the canvas is: a color
    /// the target app reported is a claim about ITS background, and whether it
    /// survives here depends on Sand's own
    /// (`AXDetailPresentation.usableForeground`).
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !model.zoomStack.isEmpty {
                breadcrumb
            }
            GeometryReader { proxy in
                ZStack(alignment: .topTrailing) {
                    Canvas { context, size in
                        guard let snapshot = model.latest else { return }
                        WireframeRenderer.draw(
                            snapshot: snapshot, plane: model.focusedPlane,
                            magnification: model.magnification,
                            detail: model.focusDetail,
                            isDark: colorScheme == .dark,
                            in: &context, size: size)
                        // SECOND PASS, ALWAYS ON TOP. Where the hands went is
                        // the one thing that must never be hidden behind the
                        // structure it acted on.
                        SandStageOverlay.draw(
                            marks: trace.marks, plane: model.focusedPlane,
                            in: &context, size: size)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                    .contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture().onEnded { value in
                            model.handleTap(at: value.location, size: proxy.size)
                        })

                    if showHUD {
                        WireframeHUD(model: model)
                            .padding(10)
                    }

                    // The ambient inspector takes the opposite corner from the
                    // HUD: it is a column of text, and sharing an edge with the
                    // instrumentation would make the wireframe itself the
                    // thinnest thing on screen.
                    if showAmbient {
                        AmbientInspectorView(model: model, availableHeight: proxy.size.height)
                            .padding(10)
                            .frame(
                                maxWidth: .infinity, maxHeight: .infinity,
                                alignment: .topLeading)
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Toggle("HUD", isOn: $showHUD)
                    .toggleStyle(.button)
            }
            ToolbarItem(placement: .automatic) {
                Toggle("Ambient", isOn: $showAmbient)
                    .toggleStyle(.button)
            }
        }
        // Derivation runs only while someone is looking — the view model holds
        // the gate so both the panel and the HUD's compact group are fed by one
        // decision.
        .onAppear { model.ambientVisible = showAmbient }
        .onChange(of: showAmbient) { _, visible in model.ambientVisible = visible }
    }

    /// "Desktop › TextEdit › Untitled" — every crumb but the last is clickable
    /// and jumps straight back to that zoom level; "Desktop" always clears the
    /// stack entirely.
    private var breadcrumb: some View {
        HStack(spacing: 4) {
            crumbButton("Desktop") { model.zoomOut(to: -1) }
            ForEach(Array(model.zoomStack.enumerated()), id: \.element.id) { index, frame in
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if index == model.zoomStack.count - 1 {
                    Text(frame.label)
                        .font(.caption.bold())
                        .lineLimit(1)
                } else {
                    crumbButton(frame.label) { model.zoomOut(to: index) }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial)
    }

    private func crumbButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.caption).lineLimit(1)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}
