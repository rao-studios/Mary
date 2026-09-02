import AppKit
import ApplicationServices
import MaryBrain
import MaryPlugin
import SwiftUI
import MaryRuntime

/// AppKit delegate: local servers and coding-agent children die with the app.
/// Cmd-Q → `applicationWillTerminate`. SIGTERM needs its own handler (AppKit
/// exits without the delegate). SIGKILL is uncatchable; orphans reaped next boot.
final class MaryAppDelegate: NSObject, NSApplicationDelegate {
    private var sigtermSource: DispatchSourceSignal?
    private var accessibilityWasGranted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        accessibilityWasGranted = AXIsProcessTrusted()
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            // Seal the open episode before the process goes.
            MaryRuntime.brainWiring.behavior.flushOpenEpisodes()
            LocalStackManager.emergencyStopAllSync()
            exit(0)
        }
        source.resume()
        sigtermSource = source
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        let accessibilityIsGranted = AXIsProcessTrusted()
        guard accessibilityIsGranted != accessibilityWasGranted else { return }
        accessibilityWasGranted = accessibilityIsGranted
        // Refresh process-wide Ability snapshot when AX grant changes. Execution still rechecks AX.
        Task.detached(priority: .utility) {
            _ = AbilityLibrary.shared.reload()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MaryRuntime.brainWiring.behavior.flushOpenEpisodes()
        LocalStackManager.emergencyStopAllSync()
    }
}

struct MaryApp: App {
    @NSApplicationDelegateAdaptor(MaryAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            Home()
                .frame(minWidth: 720, minHeight: 560)
        }
        .windowResizability(.contentMinSize)

        // Ability Studio is its own window (authoring outlives a turn). Other debug surfaces are sheets.
        // One window: browsing and authoring are the same act, on one draft.
        Window("Ability Studio", id: "ability-studio") {
            AbilityStudioView()
        }
        .defaultSize(width: 1240, height: 800)
        .windowResizability(.contentMinSize)
    }
}
