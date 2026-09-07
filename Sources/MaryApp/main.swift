import AppKit

if ProbeServers.shouldRun() {
    // Headless local-server stack; never returns.
    ProbeServers.start()
} else if ProbeSeer.shouldRun() {
    // Headless full-stack Seer turn; never returns.
    ProbeSeer.start()
} else if ProbeCursorText.shouldRun() {
    // Pastes white "hello world" at the frontmost caret; never returns.
    ProbeCursorText.start()
} else if ProbeAbilities.shouldRun() {
    // Every Skill's readiness via the app's own boot path; never returns.
    ProbeAbilities.start()
} else if ProbeAmbientSurface.shouldRun() {
    // Store tier-0 surface → prompt line; never returns.
    ProbeAmbientSurface.start()
} else {
    // SPM launches as background by default; .regular before App.main() for dock + windows.
    NSApplication.shared.setActivationPolicy(.regular)
    MaryApp.main()
}
