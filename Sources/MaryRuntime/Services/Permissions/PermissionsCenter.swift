//
//  PermissionsCenter.swift
//  Mary
//
//  Every permission Mary needs, in one place — so the asking happens once,
//  deliberately, in Settings, instead of as surprises mid-conversation.
//
//  Three kinds of permission on macOS:
//  - requestable: an API shows the system prompt (mic, speech, calendar,
//    reminders, contacts, photos, folder access, per-app Automation).
//  - manual: no prompt exists; the user flips a switch in System Settings
//    (Full Disk Access, Screen Recording, Accessibility). We deep-link the
//    exact pane and probe status where the system lets us.
//  - none: speaker output needs no permission at all.
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

    /// The Automation targets Mary's plugins script.
    ///
    /// CHROME IS CONDITIONAL, and the condition is this row's honesty. The
    /// aggregate status reads `.unknown` while ANY listed target is
    /// ungranted, so naming a browser the user does not own would leave a
    /// permanently unresolvable row nobody can clear. Installed ⇒ listed, so
    /// the row can REPAIR a denial; absent ⇒ not a target at all.
    ///
    /// TAUGHT APPLICATIONS JOIN BY THE SAME RULE. A `.mary` package that
    /// earned eyes is scripted exactly as a compiled plugin is, so its bundle
    /// belongs in this list — otherwise importing a manuscript package would
    /// leave the user staring at an Automation row that says "granted" while
    /// every ceremony in that application silently failed the consent check.
    /// Gated on `isInstalled`: a target nobody owns is a row nobody can clear.
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


    /// THE AUTOMATION TARGETS COME FROM THE ROSTER, not a list.
    ///
    /// A dozen bundle ids used to sit here, so Mary asked for Automation
    /// consent to exactly the applications somebody had thought of — and an
    /// application a user taught her got no prompt at all, which reads as
    /// Mary silently refusing to work with it.
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

    /// Ask for one target's Automation consent, but ONLY if that app is
    /// already running and consent is undetermined — never launches anything.
    /// Lets the Xcode peer-coder surface its dialog at activation (boot or
    /// settings change) instead of interrupting mid-conversation.
    static func promptAutomationIfRunning(bundleID: String) {
        let isRunning = NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier == bundleID }
        guard isRunning, automationStatus(for: bundleID) == .notDetermined else { return }
        let descriptor = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        var address = descriptor.aeDesc?.pointee ?? AEDesc()
        _ = AEDeterminePermissionToAutomateTarget(
            &address, typeWildCard, typeWildCard, true)
    }

    /// WHETHER MARY IS RUNNING AS AN APPLICATION, or as a bare development
    /// binary.
    ///
    /// THIS DECIDES WHO OWNS THE ACCESSIBILITY GRANT, which is the single
    /// most confusing thing about the permissions screen. TCC attributes a
    /// request to the RESPONSIBLE PROCESS: a binary launched from a terminal
    /// is the terminal's responsibility, so `AXIsProcessTrusted()` answers
    /// TRUE whenever that terminal has been granted — for a Mary that has
    /// never been asked about and will never appear in the Accessibility
    /// list under her own name.
    ///
    /// The symptom is exact and was reported as a bug: pressing "Grant
    /// everything" changes nothing, because the accessibility rung is
    /// already reading `.granted` and is skipped. Nothing is broken; the
    /// grant simply belongs to somebody else, and the screen said "granted"
    /// without saying to whom.
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

    /// A CORPUS APPLICATION'S LIVE-PATH CONSENTS, surfaced at activation so
    /// the dialogs land at boot, never mid-edit.
    ///
    /// The consent needed is NOT the application's own. A corpus application
    /// typically has no usable scripting dictionary — Scrivener ships an empty
    /// one — so Mary never sends it Apple Events. Every ceremony (menu
    /// click, keystroke) drives SYSTEM EVENTS, which needs (a) Automation
    /// consent for System Events and (b) Accessibility for this process:
    /// without AX, a menu click returns "OK" while doing nothing.
    ///
    /// An earlier version asked for the application's own automation, which
    /// was consent nothing ever used while the real need failed later.
    ///
    /// Only asks while one of them is already running — never launches
    /// anything, per the lean-prompt doctrine every corpus read follows.
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

    /// A BROWSER'S AUTOMATION GRANT CAME BACK DENIED mid-poll — the watcher
    /// classified errAEEventNotPermitted and called here (once per bundle
    /// per session; the lane still retracts either way). Two honest moves:
    /// a not-yet-determined grant re-fires the system dialog, and a genuine
    /// denial deposits ONE ambient fact so the next turn can say where the
    /// switch lives instead of silently going blind to tabs.
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
            world: .applications,
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

    /// The cross-app selection watcher's one consent. Unlike the two above,
    /// unconditional — there is no single app to check is running, because
    /// this watcher reads whichever app is frontmost, and some app always
    /// is. It sends no Apple Events to anything (native AX only, the same
    /// door the Pages watcher uses), so there is no Automation grant to ask
    /// for either — just the same shared one-shot Accessibility dialog.
    static func promptOtherAppsLiveConsent() {
        promptAccessibilityOnce()
    }

    /// The ephemeral look's two consents, asked at FIRST USE, not at
    /// activation: a Screen Recording dialog at boot, for a feature the
    /// user may never invoke, is the intrusive shape every other prompt
    /// here avoids — and "some app is always frontmost" does not imply
    /// consent to pixel reading. Screen Recording's dialog only points at
    /// System Settings (macOS cannot grant it in-process), so the failing
    /// turn still speaks its honest refusal; the user grants, asks again,
    /// and the look works.
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
