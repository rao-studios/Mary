//
//  AccessibilityTrustGate.swift
//  Sand
//
//  WHAT: The one permission Sand needs, asked for under Sand's own identity.
//  OUT:  onGranted → the picker
//  PIN:  Sand's grant is SEPARATE from Mary's (own bundle id, nyc.rao.sand).
//        That is the point: the bench can be trusted without the assistant
//        being trusted, and an ad-hoc rebuild that loses the grant shows up
//        here rather than as a mysteriously empty wireframe.
//
import AppKit
import ApplicationServices
import SwiftUI

@MainActor
final class AccessibilityTrustModel: ObservableObject {
    @Published var isTrusted: Bool = AXIsProcessTrusted()

    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.recheck() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func recheck() {
        isTrusted = AXIsProcessTrusted()
    }

    /// Prompts the system consent dialog once; the checkbox it adds still
    /// needs a manual flip in most cases, which `openPrivacySettings()`
    /// takes the user straight to.
    func requestPrompt() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        isTrusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    func openPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }
}

struct AccessibilityTrustGate: View {
    @StateObject private var model = AccessibilityTrustModel()
    let onGranted: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "eye.trianglebadge.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Sand needs Accessibility access")
                .font(.title2.bold())
            Text("""
            Sand reads the accessibility tree of whichever app you pick — \
            no screen recording — to draw its live wireframe, and performs \
            the abilities you run from its bench. Grant Sand its own \
            Accessibility permission (separate from Mary's) in System \
            Settings.
            """)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 420)

            HStack(spacing: 12) {
                Button("Grant Accessibility…") {
                    model.requestPrompt()
                    model.openPrivacySettings()
                }
                .buttonStyle(.borderedProminent)
                Button("I already granted it") { model.recheck() }
            }
        }
        .padding(40)
        .onChange(of: model.isTrusted) { _, granted in
            if granted { onGranted() }
        }
        .onAppear {
            if model.isTrusted { onGranted() }
        }
    }
}
