//
//  PermissionsCenter.swift
//  MaryRuntime
//
//  WHAT: Every permission Mary needs, asked once from Settings.
//  OUT:  requestable APIs / System Settings deep-links / none (speaker)
//

import AppKit
import ApplicationServices
import AVFoundation
import MaryBrain
import MaryPlugin
import Contacts
import CoreGraphics
import EventKit
import Photos
import Speech

package enum PermissionStatus: Equatable {
    case granted
    case denied
    case notDetermined
    /// Status the system won't reveal until an operation is attempted.
    case unknown
}

package struct PermissionItem: Identifiable {
    package enum Kind: String, CaseIterable {
        case microphone
        case speechRecognition
        case automation
        case screenRecording
        case accessibility
    }

    package let kind: Kind
    package var status: PermissionStatus

    package init(kind: Kind, status: PermissionStatus) {
        self.kind = kind
        self.status = status
    }

    package var id: String { kind.rawValue }

    package var title: String {
        switch kind {
        case .microphone: return "Microphone"
        case .speechRecognition: return "Speech Recognition"
        case .automation: return "App Automation"
        case .screenRecording: return "Screen Recording"
        case .accessibility: return "Accessibility"
        }
    }

    package var why: String {
        switch kind {
        case .microphone: return "hearing you"
        case .speechRecognition: return "understanding what you said"
        case .automation: return "driving the applications you taught me"
        case .screenRecording: return "real screenshots"
        case .accessibility: return "brightness keys and screen lock"
        }
    }

    /// Whether an in-app "Grant" can show the system prompt.
    package var isRequestable: Bool {
        switch kind {
        case .screenRecording, .accessibility: return false
        default: return true
        }
    }

    /// The System Settings pane for manual flips (and denied re-grants).
    var settingsPane: String {
        let base = "x-apple.systempreferences:com.apple.preference.security?"
        switch kind {
        case .microphone: return base + "Privacy_Microphone"
        case .speechRecognition: return base + "Privacy_SpeechRecognition"
        case .automation: return base + "Privacy_Automation"
        case .screenRecording: return base + "Privacy_ScreenCapture"
        case .accessibility: return base + "Privacy_Accessibility"
        }
    }
}

package enum PermissionsCenter {

    /// Automation targets Mary's plugins script. Chrome and taught apps listed
    /// only if installed — an absent target is a row nobody can clear.
    static var automationTargets: [String] {
        var targets = baseAutomationTargets
        for registration in AmbientApplicationIndexProvider.current.all
        where registration.place.application != nil && registration.hasEyes {
            // EXACT IDS ONLY. Consent is granted per process identity, and a
            // declared FAMILY prefix is not a bundle id — TCC cannot be asked
            // about one, so listing it would add a row that can never clear.
            for bundleID in registration.bundleIdentifiers.sorted()
            where isInstalled(bundleID) && !targets.contains(bundleID) {
                targets.append(bundleID)
            }
        }
        return targets
    }


    /// Automation targets come from the roster, not a hardcoded list.
    private static var baseAutomationTargets: [String] {
        AmbientApplicationIndexProvider.current.all
            .flatMap { $0.bundleIdentifiers.sorted() }
            .sorted()
    }

    private static func isInstalled(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    // MARK: - Status

    package static func currentStatus() -> [PermissionItem] {
        PermissionItem.Kind.allCases.map { kind in
            PermissionItem(kind: kind, status: status(of: kind))
        }
    }

    package static func status(of kind: PermissionItem.Kind) -> PermissionStatus {
        switch kind {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        case .speechRecognition:
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        case .automation:
            return automationStatus()
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : .denied
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .denied
        }
    }

    private static func folderStatus(_ path: String) -> PermissionStatus {
        // Listing succeeds once granted; before the first attempt macOS
        // reveals nothing — an unreadable listing after an attempt is denial.
        if (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil {
            return .granted
        }
        return .unknown
    }

    private static func automationStatus() -> PermissionStatus {
        var granted = 0
        var determined = 0
        for bundleID in automationTargets {
            switch automationStatus(for: bundleID) {
            case .granted: granted += 1; determined += 1
            case .denied: determined += 1
            default: break
            }
        }
        if determined == 0 { return .notDetermined }
        if granted == determined && determined == automationTargets.count { return .granted }
        if granted == 0 { return .denied }
        return .unknown   // mixed — some granted, some not
    }

    static func automationStatus(for bundleID: String) -> PermissionStatus {
        let descriptor = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        var address = descriptor.aeDesc?.pointee ?? AEDesc()
        let status = AEDeterminePermissionToAutomateTarget(
            &address, typeWildCard, typeWildCard, false)
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
        default: return .unknown   // procNotFound: target isn't running
        }
    }

    // MARK: - Requests (each shows the system prompt at most once — macOS
    // remembers every answer)

    @discardableResult
    package static func request(_ kind: PermissionItem.Kind) async -> PermissionStatus {
        switch kind {
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .speechRecognition:
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
            }
        case .automation:
            await requestAllAutomation()
        case .screenRecording:
            // Shows the system dialog pointing at the Settings pane.
            _ = CGRequestScreenCaptureAccess()
        case .accessibility:
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        return status(of: kind)
    }

    /// Trigger each Automation target's consent prompt: launch it quietly,
    /// then ask the Apple Event permission question with consent allowed.
    static func requestAllAutomation() async {
        for bundleID in automationTargets {
            if automationStatus(for: bundleID) == .granted { continue }
            // The target must be running for the consent prompt to appear.
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                configuration.hides = true
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
            let descriptor = NSAppleEventDescriptor(bundleIdentifier: bundleID)
            var address = descriptor.aeDesc?.pointee ?? AEDesc()
            _ = AEDeterminePermissionToAutomateTarget(
                &address, typeWildCard, typeWildCard, true)
        }
    }

    /// Ask Automation if the app is running and consent is undetermined. Never launches.
    static func promptAutomationIfRunning(bundleID: String) {
        let isRunning = NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier == bundleID }
        guard isRunning, automationStatus(for: bundleID) == .notDetermined else { return }
        let descriptor = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        var address = descriptor.aeDesc?.pointee ?? AEDesc()
        _ = AEDeterminePermissionToAutomateTarget(
            &address, typeWildCard, typeWildCard, true)
    }

    /// Running as an app vs a terminal binary. TCC attributes AX to the
    /// responsible process — terminal-launched Mary reads the terminal's grant.
    package static var runsAsApplication: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    /// The name macOS will have listed instead of Mary, when the grant was
    /// inherited. Nil when Mary is a real application and owns her own.
    package static var accessibilityGrantHolder: String? {
        guard !runsAsApplication, AXIsProcessTrusted() else { return nil }
        return ProcessInfo.processInfo.environment["TERM_PROGRAM"]
            ?? "the process that launched Mary"
    }

    /// One AX prompt per app run — repeated system dialogs would nag.
    nonisolated(unsafe) private static var accessibilityPromptFired = false

    /// The once-per-run Accessibility ask, shared by every live path that
    /// needs AX (Scrivener ceremonies, the Pages selection watcher, the
    /// typer) — whichever activates first fires the single dialog.
    private static func promptAccessibilityOnce() {
        if !AXIsProcessTrusted(), !accessibilityPromptFired {
            accessibilityPromptFired = true
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
    }

    /// Corpus live-path consents at activation: System Events Automation + AX.
    /// Ask only while the app is running — never launches.
    static func promptCorpusLiveConsents(bundleIdentifiers: [String]) {
        let wanted = Set(bundleIdentifiers.map { $0.lowercased() })
        guard !wanted.isEmpty else { return }
        let running = NSWorkspace.shared.runningApplications.contains {
            guard let id = $0.bundleIdentifier?.lowercased() else { return false }
            return wanted.contains(id)
        }
        guard running else { return }
        promptAutomationIfRunning(bundleID: "com.apple.systemevents")
        promptAccessibilityOnce()
    }

    /// Browser Automation denied mid-poll. Undetermined → re-prompt; denial → one ambient fact.
    static func noteBrowserAutomationDenied(bundleID: String) {
        if automationStatus(for: bundleID) == .notDetermined {
            promptAutomationIfRunning(bundleID: bundleID)
            return
        }
        let name = NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == bundleID }?.localizedName
            ?? AmbientApplicationIndexProvider.current
                .registration(bundleID: bundleID)?.displayName
            ?? "the browser"
        AmbientContextStore.shared.register(AmbientFact(
            attention: .applications,
            application: AmbientPlaceResolver.browserApplicationID,
            slot: .file,
            content: "I can't see \(name)'s tabs — its Automation permission for me is off. It lives in System Settings, Privacy & Security, Automation, under Mary.",
            applicationID: bundleID,
            provenance: .derived,
            registration: .perceived,
            // A denial is durable until the user flips it; hold the fact a
            // few poll cycles so the next turns can speak it, without
            // asserting it forever.
            freshFor: 10 * 60))
    }

    static func promptPagesLiveConsents(pagesBundleID: String) {
        let pagesRunning = NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier == pagesBundleID }
        guard pagesRunning else { return }
        promptAutomationIfRunning(bundleID: pagesBundleID)
        promptAccessibilityOnce()
    }

    /// Cross-app selection watcher: shared one-shot AX dialog. No Automation (native AX).
    static func promptOtherAppsLiveConsent() {
        promptAccessibilityOnce()
    }

    /// Look consents at first use, not boot. Screen Recording dialog points at System Settings.
    static func promptLookingConsents() {
        promptAccessibilityOnce()
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
    }

    /// Every prompt-showing request, in one deliberate pass. Manual grants
    /// (Full Disk Access) stay manual — the UI deep-links them.
    package static func requestAllRequestable() async {
        for kind in PermissionItem.Kind.allCases where PermissionItem(kind: kind, status: .unknown).isRequestable {
            if status(of: kind) == .granted { continue }
            _ = await request(kind)
        }
        // These two show a Settings-pointing dialog rather than a grant.
        if status(of: .screenRecording) != .granted { _ = await request(.screenRecording) }
        if status(of: .accessibility) != .granted { _ = await request(.accessibility) }
    }

    package static func openSettingsPane(_ item: PermissionItem) {
        if let url = URL(string: item.settingsPane) {
            NSWorkspace.shared.open(url)
        }
    }
}
