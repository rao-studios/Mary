import AppKit

if ProbeChat.shouldRun() {
    // Headless one-turn chat for terminal testing; never returns.
    ProbeChat.start()
} else if ProbeServers.shouldRun() {
    // Headless local-server stack exercise; never returns.
    ProbeServers.start()
} else if ProbeSeer.shouldRun() {
    // Headless full-stack Seer turn; never returns.
    ProbeSeer.start()
    // Signed, clipboard-preserving Pages selection diagnostic; never returns.
} else if ProbeCursorText.shouldRun() {
    // Pastes white "hello world" at the frontmost app's caret; never returns.
    ProbeCursorText.start()
} else if ProbeAbilities.shouldRun() {
    // Prints every Skill's readiness from the app's own boot path; never returns.
    ProbeAbilities.start()
} else if ProbeAmbientSurface.shouldRun() {
    // Follows that same walk into the store's tier-0 surface and back out as
    // the line the prompt renders; never returns.
    ProbeAmbientSurface.start()
} else {
    // SPM executables launch as background processes by default. Setting .regular
    // before App.main() makes macOS treat this as a normal foreground app with a
    // dock icon and windows.
    NSApplication.shared.setActivationPolicy(.regular)
    MaryApp.main()
}
