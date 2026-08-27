import AppKit
import ApplicationServices
import MaryBrain
import MaryAdapters
import SwiftUI
import MaryRuntime

/// The app's only AppKit delegate duty: make sure local servers and delegated
/// coding-agent children die with the app. Cmd-Q lands in applicationWillTerminate;
/// SIGTERM (kill, launchd shutdown) gets its own handler because AppKit
/// exits on it WITHOUT the delegate callback. SIGKILL remains uncatchable;
/// LocalStackManager can only reap its own server orphans on the next boot.
final class MaryAppDelegate: NSObject, NSApplicationDelegate {
    private var sigtermSource: DispatchSourceSignal?
    private var accessibilityWasGranted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        accessibilityWasGranted = AXIsProcessTrusted()
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            // THE OPEN EPISODE IS SEALED BEFORE THE PROCESS GOES.
            //
            // A turn interrupted by a quit really happened, and everything in
            // it that SETTLED is a fact about the world. Losing it because
            // the process ended is the one case where the record would be
            // silently incomplete — and silence is the failure mode the whole
            // dataset is built to avoid.
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
        // Dynamic provider readiness is frozen per Ability snapshot. Refresh
        // process-wide whenever macOS changes the grant, whether or not the
        // Settings sheet happens to be open. Execution still rechecks AX at
        // the last responsible moment.
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
    }
}
