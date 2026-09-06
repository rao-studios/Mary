//
//  BrowserEngineSeams.swift
//  MaryPlugin
//
//  WHAT: The four things the browser engine can do to a machine, as protocols.
//  IN:   BrowserEngine.Seams
//  OUT:  .live wires each to MaryComputerUse
//  PIN:  SEAMS SO THE ENGINE IS TESTABLE WITHOUT A BROWSER. Every refusal path and
//        every verification failure has to be reachable in a test, and none of them is
//        reachable if the engine can only be exercised by driving Safari by hand.
//        The live implementations are thin on purpose — they add nothing the machine
//        layer does not already do, so the seam costs no behaviour.
//

import AppKit
import OSLog
import CoreGraphics
import Foundation
import MaryAmbient
import MaryComputerUse
import MaryFoundation

/// Reading and driving the browser's own shell.
public protocol BrowserShellReading: Sendable {
    func read(pid: pid_t, registration: WebSurfaceRegistration) async -> WebSurfaceAX.Reading?
    func openLocation(_ address: String, pid: pid_t, registration: WebSurfaceRegistration) async -> Bool
    /// Press a shell control by its declared label.
    func press(label: String, pid: pid_t, registration: WebSurfaceRegistration) async -> Bool
}

/// Reading the page itself.
public protocol PagePerceiving: Sendable {
    func read(
        pid: pid_t, windowID: CGWindowID?, pageFrame: CGRect,
        intent: VisionPageReader.Intent, appName: String, windowTitle: String,
        previousFraction: Double?, previousElapsed: TimeInterval?
    ) async throws -> VisionPageReader.Reading
}

/// HOW MUCH THE PAGE IS OFFERING RIGHT NOW, cheaply.
///
/// PIN: A SETTLE NEEDS A SIGNAL, NOT A SLEEP, AND THE SIGNAL MUST BE CHEAP. A
/// results page was read after a flat 900ms and the reading came back with 79
/// rows where a read a moment later found 107 — no result groups formed, the
/// openResult class unanswerable, and the failure filed against the detector's
/// recall. Reading the whole page twice to find that out would double the cost
/// of every search, so the settle polls the browser's OWN accessibility tree,
/// which is a bounded walk of a few hundred nodes, and the expensive read
/// happens once, after the count stops moving.
public protocol PageSettling: Sendable {
    /// How many things the page's own tree publishes, or nil when it cannot say
    /// — a host with no web content, a tree that never woke. Nil settles nothing
    /// and the caller falls back to waiting.
    func offering(pid: pid_t, pageFrame: CGRect) async -> Int?
}

/// The pointer.
public protocol BrowserHands: Sendable {
    func move(to point: CGPoint, pid: pid_t) async
    func click(at point: CGPoint, button: PluginPointerButton, count: Int, pid: pid_t) async
    func scroll(at point: CGPoint, by delta: Double, pid: pid_t) async
    /// Put the pointer itself over a point. See PointerDriver.hover — a long approach,
    /// which is what wakes a player's transport.
    func hover(at point: CGPoint, pid: pid_t) async
    /// A short travel from where the pointer already is, disturbing nothing on the way.
    func glide(to point: CGPoint, pid: pid_t) async
    func drag(from: CGPoint, to: CGPoint, duration: Double, pid: pid_t) async
    /// Where the pointer was before any of this, so it can be put back.
    func cursorLocation() async -> CGPoint?
    func restoreCursor(to point: CGPoint?) async
}

/// The keys a page may be sent.
///
/// PIN: THREE KEYS AND TYPING, AND NOTHING ELSE. A modified chord inside a page is a
/// BROWSER command and an unmodified letter is a SITE shortcut — the two things this
/// discipline exists not to use. `NoSiteShortcutsTests` reads this file expecting the
/// presses below to be literal and unmodified.
public protocol BrowserKeys: Sendable {
    func type(_ text: String, targetPrefix: String) async -> Bool
    func press(_ key: PageInteractionKey) async -> Bool
}

public extension BrowserHands {
    /// One ordinary left click.
    func click(at point: CGPoint, pid: pid_t) async {
        await click(at: point, button: .left, count: 1, pid: pid)
    }

    /// Wake a player's transport by moving the pointer ACROSS its picture.
    ///
    /// PIN: TWO POINTS, NOT ONE. A player reveals its controls on mouse MOVEMENT, and a
    /// single event at a fixed coordinate is not movement — measured against YouTube,
    /// where one posted `mouseMoved` left the transport hidden and the page read as a
    /// video with no controls at all. Two events a few points apart is a move, and the
    /// second one is where the pointer is left so the controls stay up for the read.
    func reveal(over frame: CGRect, pid: pid_t) async {
        await reveal(over: frame, at: 0.35, pid: pid)
    }

    /// `depth` is how far down the captured region to land, as a fraction. Retries use
    /// different depths, because a page is only a player over part of what was captured
    /// and one fraction cannot be right for every layout.
    func reveal(over frame: CGRect, at depth: Double, pid: pid_t) async {
        // ONE TRAVEL, INTO THE PICTURE. `hover` already starts well outside the target
        // and moves in, which is the entry a player reveals on; a second hover before it
        // only spends time and moves the pointer somewhere the page has to react to
        // first.
        //
        // The middle of the PICTURE, which on a watch page is the upper half of what was
        // captured — the lower half is the title and comments, and hovering there
        // reveals nothing.
        let centre = CGPoint(
            x: frame.midX.rounded(),
            y: (frame.minY + frame.height * CGFloat(min(max(depth, 0.05), 0.95))).rounded())
        await hover(at: centre, pid: pid)
    }
}

/// Who holds the machine.
///
/// PIN: THE STAGE IS TAKEN AND GIVEN BACK, AND THE REASON IT COULD NOT BE TAKEN
/// IS KEPT. This used to answer `Bool`, so five different conditions — not
/// running, no window on screen, another act holding the stage, cancelled,
/// refused — reached the person as one sentence. And nothing ever put the
/// previous application back: "mute the video" said from an editor left the
/// browser in front, which the doctrine (invariant 3) says it must not.
public protocol BrowserStaging: Sendable {
    /// The regular application in front before anything moves — what an act
    /// that answers a question gives the stage back to. Nil when nothing is owed.
    func frontmost() async -> pid_t?
    /// Take the stage for one act: the lease, the hold, and the window brought
    /// forward and proved.
    func bringForward(pid: pid_t) async -> Activation
    /// The act is over. Release the stage, and put `previous` back in front when
    /// one is named.
    func standDown(givingBackTo previous: pid_t?) async
    /// Is this still the process in front? A plan that keeps pressing into whatever
    /// came forward is worse than one that stops and says where it got to.
    func holdsFocus(pid: pid_t) async -> Bool
}

// MARK: - Live

struct LiveBrowserShell: BrowserShellReading {
    private static let log = Logger(subsystem: "nyc.rao.mary", category: "browsing")
    func read(pid: pid_t, registration: WebSurfaceRegistration) async -> WebSurfaceAX.Reading? {
        WebSurfaceAX.read(pid: pid, registration: registration)
    }

    /// Once, then verified. `openLocation` retries this whole exchange rather than
    /// trusting a single run.
    static let addressTypingAttempts = 3
    /// How long the field needs after the last keystroke before its own value can be
    /// trusted — not measured, chosen to sit above `KeyboardTyper`'s 25ms inter-chunk
    /// gap with headroom for the omnibox's own reflow.
    static let addressVerifySettle = Duration.milliseconds(150)

    /// Focus the address field, replace what is in it, and commit.
    ///
    /// PIN: THE FULL ADDRESS IS TYPED, SCHEME AND ALL. Both omniboxes autocomplete
    /// inline as you type, and a bare host can be completed to a different address
    /// between the last character and Return.
    /// PIN: TYPED, THEN PROVED, BEFORE IT IS TRUSTED. Measured live: "Let's watch a
    /// fred again video on youtube" landed as "red again video on youtube". Chunk one —
    /// `KeyboardTyper` posts at most 16 UTF-16 units per synthetic keystroke, 25ms apart
    /// — is "Let's watch a fr"; the omnibox inline-autocompletes and SELECTS a
    /// suggestion reacting to it before chunk two arrives, and chunk two's keystroke
    /// then REPLACES that selection instead of appending, wiping chunk one whole. A
    /// query longer than one chunk is not a rare shape — the whole request sentence
    /// lands here whenever nothing upstream stripped its preamble — so this is
    /// reachable on an ordinary sentence, not an edge case. `KeyboardTyper` cannot fix
    /// this from inside a chunk (each chunk completes honestly; the corruption is
    /// between them), so the field is READ BACK and RETYPED here until it agrees with
    /// what was meant, the same "prove it by looking again" rule the rest of this file
    /// already lives by.
    func openLocation(
        _ address: String, pid: pid_t, registration: WebSurfaceRegistration
    ) async -> Bool {
        guard await focusAddressField(pid: pid, registration: registration) else { return false }
        for attempt in 1...Self.addressTypingAttempts {
            // Select all, so typing replaces rather than appends.
            // AIMED, like the focus chord above it: ⌘A in somebody else's window
            // selects their document, and the typing that follows replaces it.
            guard KeyChordPress.press(
                key: .a, modifiers: [.command],
                targetPrefix: registration.bundleIdentifiers.first)
            else { return false }
            let typed = await KeyboardTyper.type(
                address, targetPrefix: registration.bundleIdentifiers.first ?? "")
            // A PARTIAL ADDRESS MUST NOT BE COMMITTED. Losing focus halfway through
            // leaves half a URL in the field, and pressing Return then navigates
            // somewhere nobody asked for — worse than not navigating at all.
            guard case .completed = typed else { return false }
            try? await Task.sleep(for: Self.addressVerifySettle)
            let readback = WebSurfaceAX.addressFieldValue(pid: pid, registration: registration)
            let landed = Self.addressLanded(intended: address, fieldValue: readback)
            guard landed else {
                // SAY WHY, WITHOUT SAYING WHAT. A refused readback used to be a
                // silent `continue` three times and then "couldn't find the
                // address bar" — a sentence about a control that was found and
                // typed into. The shape of the mismatch is the diagnosis; the
                // address itself is held, never logged, like everywhere else.
                Self.log.info(
                    "address readback refused — attempt \(attempt) typed \(address.count) read \(readback?.count ?? -1) scheme=\(readback?.lowercased().hasPrefix("http") == true) empty=\(readback?.isEmpty ?? true)")
                if attempt == Self.addressTypingAttempts { return false }
                continue
            }
            // AND THE COMPLETION THE BROWSER ADDED MUST BE REMOVED BEFORE RETURN.
            //
            // PIN: BOTH OMNIBOXES FINISH YOUR SENTENCE, and Return accepts what they
            // wrote rather than what was typed. Measured live: "swift concurrency"
            // typed into Chrome opened YouTube, because a history entry was
            // inline-completed and selected. Forward-delete removes a selected
            // completion and does nothing at all when there is none, which is exactly
            // the shape of fix this needs — it cannot damage the honest case. It is a
            // text-editing key inside a text field, not a page shortcut; see
            // NoSiteShortcutsTests, which admits it for that reason.
            let aimed = registration.bundleIdentifiers.first
            _ = KeyChordPress.press(
                key: .forwardDelete, modifiers: [], targetPrefix: aimed)
            return KeyChordPress.press(key: .return, modifiers: [], targetPrefix: aimed)
        }
        return false
    }

    /// Did the field actually receive what was typed? A trailing autocomplete
    /// suggestion is expected and ignored — only the FRONT of the field is proof,
    /// because that is exactly the part a chunk-boundary race wipes.
    static func addressLanded(intended: String, fieldValue: String?) -> Bool {
        guard let fieldValue else { return false }
        if fieldValue.hasPrefix(intended) { return true }
        // CHROME ELIDES WHAT IT DISPLAYS. The moment the omnibox recognises a
        // typed address it shows it without its scheme, and without a leading
        // "www." — so the field reads "en.wikipedia.org/…" for a typed
        // "https://en.wikipedia.org/…", and the literal prefix test above called
        // a correct type a failed one, three times over, and refused the whole
        // navigation as "couldn't find the address bar". MEASURED LIVE: it
        // worked while the address was new and failed once it was in history and
        // being completed. What is compared is the typed address with the same
        // elisions applied, and nothing looser — a completion to a DIFFERENT
        // address still has to fail here so forward-delete can remove it.
        let elided = Self.displayForm(intended)
        return fieldValue.hasPrefix(elided) || Self.displayForm(fieldValue).hasPrefix(elided)
    }

    /// An address as the omnibox displays it: no scheme, no leading "www.".
    static func displayForm(_ address: String) -> String {
        var value = address
        for scheme in ["https://", "http://"] where value.lowercased().hasPrefix(scheme) {
            value = String(value.dropFirst(scheme.count))
            break
        }
        if value.lowercased().hasPrefix("www.") { value = String(value.dropFirst(4)) }
        return value
    }

    private func focusAddressField(
        pid: pid_t, registration: WebSurfaceRegistration
    ) async -> Bool {
        // The declared chord is the browser's OWN menu command for focusing its address
        // field. It is shell, not a site shortcut — the distinction the whole browsing
        // discipline turns on.
        KeyChordPress.press(
            key: registration.schema.addressFocusKey,
            modifiers: registration.schema.addressFocusModifiers,
            // AIMED, so it can never land in whatever came forward. See
            // `KeyChordPress.press(key:modifiers:targetPrefix:)`.
            targetPrefix: registration.bundleIdentifiers.first)
    }

    /// Press a shell control by its declared label — the control's OWN action
    /// first, and a real click only if it has none.
    ///
    /// PIN: A PID-POSTED CLICK ON CHROME'S TOOLBAR DOES NOTHING. Measured live
    /// and unambiguously: the Back button was found and clicked, and the title,
    /// `canGoBack` and `canGoForward` were all identical five polls later — Mary
    /// then said "Went back" about a page she had never left. `AXPress` is the
    /// button's own action, it is what an assistive client is meant to send, and
    /// it is less invasive than synthesizing input. The click stays as the
    /// fallback for a control that publishes no press action, and goes through
    /// the HID tap rather than the process, for the reason the page lane already
    /// records: a posted click is invisible to rendered content.
    func press(label: String, pid: pid_t, registration: WebSurfaceRegistration) async -> Bool {
        let wanted = WebSurfaceRegistration.folded(label)
        guard let application = AXUIElementCreateApplication(pid) as AXUIElement?
        else { return false }
        guard let control = Self.control(named: wanted, in: application) else { return false }

        // Through Hands, so the monitor sees it — the seam locates, the machine
        // layer acts.
        if PageElementActions.press(control: control, pid: pid, detail: "shell \(label)") {
            return true
        }
        guard let frame = AX.frame(of: control), frame.width > 1, frame.height > 1
        else { return false }
        return PointerDriver.clickThroughHID(
            at: CGPoint(x: frame.midX.rounded(), y: frame.midY.rounded()),
            button: .left, count: 1)
    }

    /// The live control whose folded label matches, walked from the application.
    ///
    /// PIN: A LIVE ELEMENT, NOT A SNAPSHOT NODE. The walk this replaced produced
    /// plain Sendable values, which carry a frame and no way to send the control
    /// its own action — which is why the press was a coordinate click at all.
    static func control(named wanted: String, in application: AXUIElement) -> AXUIElement? {
        var found: AXUIElement?
        var seen = 0
        func walk(_ element: AXUIElement) {
            guard found == nil, seen < 4_000 else { return }
            seen += 1
            let label = (AX.string(element, kAXTitleAttribute as String) ?? "")
                + " " + (AX.string(element, kAXDescriptionAttribute as String) ?? "")
            if WebSurfaceRegistration.folded(label) == wanted
                || WebSurfaceRegistration.folded(
                    AX.string(element, kAXTitleAttribute as String) ?? "") == wanted {
                // A DISABLED CONTROL IS NOT THE ONE. There is nowhere to go.
                if AX.attribute(element, kAXEnabledAttribute as String) as? Bool != false {
                    found = element
                    return
                }
            }
            for child in AX.children(element, kAXChildrenAttribute as String) {
                walk(child)
            }
        }
        walk(application)
        return found
    }
}

/// THE DEFAULT, WHICH SETTLES NOTHING. A caller that has not been given a signal
/// waits out its budget exactly as it did before this seam existed — the fakes get
/// this, and so does anything constructing seams by hand.
public struct NothingToSettle: PageSettling {
    public init() {}
    public func offering(pid: pid_t, pageFrame: CGRect) async -> Int? { nil }
}

struct LivePageSettling: PageSettling {
    func offering(pid: pid_t, pageFrame: CGRect) async -> Int? {
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        let readiness = await BrowserAXReadiness.ensureWebContentAX(
            pid: pid, bundleID: bundleID,
            timeout: BrowserAXReadiness.readSettleTimeout)
        guard readiness.walkable else { return nil }
        let rows = PageElementReader.readWebContent(
            in: AXUIElementCreateApplication(pid), pageFrame: pageFrame)
        return rows.isEmpty ? nil : rows.count
    }
}

struct LivePagePerception: PagePerceiving {
    func read(
        pid: pid_t, windowID: CGWindowID?, pageFrame: CGRect,
        intent: VisionPageReader.Intent, appName: String, windowTitle: String,
        previousFraction: Double?, previousElapsed: TimeInterval?
    ) async throws -> VisionPageReader.Reading {
        // THE PIPELINE, NOT THE READER. A second perception lane joins there, and the
        // engine must not have to learn about it. See PagePerceptionPipeline.
        try await PagePerceptionPipeline.read(
            pid: pid, windowID: windowID, pageFrame: pageFrame, intent: intent,
            appName: appName, windowTitle: windowTitle,
            previousFraction: previousFraction, previousElapsed: previousElapsed)
    }
}

public struct LiveBrowserHands: BrowserHands {
    public init() {}

    public func move(to point: CGPoint, pid: pid_t) async {
        PointerDriver.move(to: point, pid: pid)
    }

    /// PIN: THROUGH THE SAME TAP A MOUSE USES, not posted to the process.
    ///
    /// A pid-posted click is invisible to rendered page content — measured repeatedly on
    /// YouTube, where a correctly aimed press on the play button reported success and
    /// moved nothing, in both delivery orders and with the cursor already on the target.
    /// The engine puts the pointer ON the control first, so the press goes exactly where
    /// the user can see the pointer sitting; that is what bounds a global tap's risk
    /// here. Browser CHROME is still pressed through Accessibility, which does work.
    public func click(
        at point: CGPoint, button: PluginPointerButton, count: Int, pid: pid_t
    ) async {
        PointerDriver.clickThroughHID(at: point, button: button, count: count)
    }

    public func scroll(at point: CGPoint, by delta: Double, pid: pid_t) async {
        PointerDriver.scroll(at: point, deltaX: 0, deltaY: delta, pid: pid)
    }

    public func hover(at point: CGPoint, pid: pid_t) async {
        PointerDriver.hover(at: point, pid: pid)
    }

    public func glide(to point: CGPoint, pid: pid_t) async {
        PointerDriver.glideThroughHID(to: point)
    }

    /// PIN: THROUGH THE HARDWARE TAP, like the click and for the same measured reason —
    /// a pid-posted drag is invisible to rendered content, so a slider dragged that way
    /// reports success and moves nothing.
    public func drag(from: CGPoint, to: CGPoint, duration: Double, pid: pid_t) async {
        PointerDriver.dragThroughHID(from: from, to: to, duration: duration)
    }

    public func cursorLocation() async -> CGPoint? { PointerDriver.location }

    public func restoreCursor(to point: CGPoint?) async { PointerDriver.restore(to: point) }
}

public struct LiveBrowserKeys: BrowserKeys {
    public init() {}

    public func type(_ text: String, targetPrefix: String) async -> Bool {
        // A PARTIAL STRING MUST NOT BE COMMITTED — the same rule the address bar keeps.
        // Losing focus halfway leaves half a phrase somewhere nobody asked for.
        guard case .completed = await KeyboardTyper.type(text, targetPrefix: targetPrefix)
        else { return false }
        return true
    }

    /// Written as literal cases on purpose: the source scan that forbids site shortcuts
    /// reads these lines, and a press assembled from a variable would tell it nothing.
    public func press(_ key: PageInteractionKey) async -> Bool {
        switch key {
        case .return: return KeyChordPress.press(key: .return, modifiers: [])
        case .escape: return KeyChordPress.press(key: .escape, modifiers: [])
        case .tab: return KeyChordPress.press(key: .tab, modifiers: [])
        }
    }
}

/// The live stage: the same lease and the same hold the typer and the
/// affordance recipes take, and the same activation faculty every act uses.
///
/// PIN: THE BROWSER TOOK NEITHER, AND COULD BE PREEMPTED MID-PLAN. `StageArbiter`
/// is how one act keeps another off the machine while it is driving; the
/// self-driving hold is how the focus tracker knows the activations it sees are
/// Mary's ceremony and not the person's intent. Every other lane that stages
/// takes both; the browser stages more than any of them and took none.
public final class LiveBrowserStaging: BrowserStaging, @unchecked Sendable {
    private let lock = NSLock()
    private var lease: UUID?
    private var hold: UUID?

    public init() {}

    public func frontmost() async -> pid_t? {
        await VerifiedActivation.frontmostRegularApplication()
    }

    public func bringForward(pid: pid_t) async -> Activation {
        guard let taken = await StageArbiter.shared.acquire(owner: "browsing", onPreempt: {})
        else {
            return .lost(.stageHeld(StageArbiter.shared.currentOwner() ?? "another act"))
        }
        let holding = WorkspaceFocusTracker.shared.beginSelfDriving()
        lock.withLock {
            lease = taken
            hold = holding
        }
        let activation = await VerifiedActivation.bringForward(pid: pid)
        if !activation.succeeded { await standDown(givingBackTo: nil) }
        return activation
    }

    public func standDown(givingBackTo previous: pid_t?) async {
        let held = lock.withLock { () -> (UUID?, UUID?) in
            defer {
                lease = nil
                hold = nil
            }
            return (lease, hold)
        }
        if let previous {
            // THE PERSON'S PLACE, GIVEN BACK. Not proved to a visible window —
            // it was in front a moment ago and is being handed what it had.
            await VerifiedActivation.bringForward(pid: previous, requireVisibleWindow: false)
        }
        if let lease = held.0 { StageArbiter.shared.release(lease) }
        if let hold = held.1 { WorkspaceFocusTracker.shared.endSelfDriving(hold) }
    }

    public func holdsFocus(pid: pid_t) async -> Bool {
        await VerifiedActivation.isFrontmost(pid: pid)
    }
}
