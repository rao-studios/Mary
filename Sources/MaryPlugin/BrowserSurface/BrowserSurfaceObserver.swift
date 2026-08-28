//
//  BrowserSurfaceObserver.swift
//  MaryPlugin
//
//  THE BROWSER'S SLATE, PUBLISHED FROM THE PAGE — the other half of a
//  carve-out that has been honoured from one side only.
//
//  `AmbientSurfaceObserver` publishes the affordance slate for every family
//  EXCEPT a browser, where it retracts and stands down. Its header says why,
//  and names the file that was meant to fill the gap: "`BrowserContextWatcher`
//  publishes the browser place's slate from the page rather than the window,
//  and two publishers writing one scope is how two lanes start disagreeing."
//  Until now nothing did, so a browser's affordance scope was permanently
//  empty — the carve-out was a promise kept on one side.
//
//  WHY THE PAGE AND NOT THE WINDOW, which is the whole reason for the
//  carve-out. A window-rooted read of a browser finds the address bar, the
//  bookmarks, the tab strip and the toolbar — furniture, all of it
//  pressable, none of it what anybody means by "click the sign-in link". The
//  page is the part the user is looking at, and it is the only part of a
//  browser window whose controls are worth resolving a phrase against.
//
//  IT PUBLISHES ONLY WHAT IT CAN SEE. A browser whose page has not been
//  exposed to Accessibility yet publishes NOTHING rather than an empty slate
//  presented as "this page offers nothing" — those are different claims, and
//  the second one is a confident lie. Retraction is reserved for leaving a
//  browser, where an emptied scope is exactly right.
//
//  ONE SLATE AT A TIME, the tier-0 observer's rule kept verbatim: moving
//  between browsers retracts the previous place's scope before the next one
//  publishes. A stale affordance is a confidently wrong press waiting for a
//  phrase.
//

import AppKit
import ApplicationServices
import Foundation
import MaryAmbient
import MaryFoundation
import os

public final class BrowserSurfaceObserver: MaryObserver, @unchecked Sendable {

    public static let shared = BrowserSurfaceObserver()

    /// ⚠️ NOT `browser-surface`. That is the ADAPTER's id, and an observer
    /// sharing it publishes a second manifest under one identity — which
    /// `duplicate-adapter-manifest` refuses, rejecting the WHOLE package
    /// graph rather than the observer. The symptom is every package failing
    /// to load at once, for a reason that names an adapter nobody touched.
    ///
    /// The two are different things about the same lane: the adapter ANSWERS
    /// about a browser, this WATCHES its page.
    public let id = "browser-page"

    /// The tier-0 observer's cadence, deliberately matched. Two pollers on
    /// different beats would make "what is on screen" depend on which one
    /// last ran, and the browser's slate must not be fresher or staler than
    /// the surface it belongs beside.
    static let activeInterval: Duration = .seconds(10)
    static let idleInterval: Duration = .seconds(45)

    private let claim = SinglePollerClaim()
    private let publishedBox = OSAllocatedUnfairLock<AmbientElementScope?>(initialState: nil)
    /// What was published last, so an unchanged page skips re-vectorizing —
    /// the same economy the tier-0 observer makes, and for the same reason:
    /// this is the publication that costs an embedding pass.
    private let lastBox = OSAllocatedUnfairLock<(pid: pid_t, signature: [String])?>(
        initialState: nil)

    private let support: BrowserSurfaceSupport
    private let elementIndex: AmbientElementIndexStore

    public init(
        support: BrowserSurfaceSupport = .shared,
        elementIndex: AmbientElementIndexStore = .shared
    ) {
        self.support = support
        self.elementIndex = elementIndex
    }

    // MARK: - MaryObserver

    // THE SAME SENSE THE TIER-0 OBSERVER CLAIMS: this watches what is in
    // front, and differs only in reading the page rather than the window.
    public let ambientSenses: Set<AmbientSense> = [.workspace]

    public var providedPerceptions: Set<PerceptionID> { ["perception.browser-page"] }

    /// NOTHING IN THE PROMPT. The slate is a searchable index, not a standing
    /// line — a browser's page can hold sixty controls, and none of them
    /// belongs in every turn's budget. The tab roster reaches the model
    /// through `list_tabs` when it is asked for.
    public func promptContribution() -> String? { nil }

    public var observedPlace: AmbientPlace? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              let bundleID = front.bundleIdentifier,
              AmbientPlaceResolver.isBrowser(bundleID: bundleID)
        else { return nil }
        return AmbientPlaceResolver.browserPlace
    }

    public var ambientLine: String? { nil }

    public var holdsWholeDocument: Bool { false }

    public func activate() async {
        _ = claim.claim { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshAmbientContext()
                let interval = self.observedPlace == nil
                    ? Self.idleInterval : Self.activeInterval
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
    }

    /// RETRACT ON THE WAY OUT. A poller that stops without emptying its scope
    /// leaves a page's controls in the index for a browser that is no longer
    /// being watched — and a phrase would still resolve against them.
    public func deactivate() async {
        claim.release()
        retract()
    }

    public func refreshAmbientContext() async {
        guard !support.all().isEmpty else { return }
        guard let front = NSWorkspace.shared.frontmostApplication,
              let bundleID = front.bundleIdentifier,
              let registration = support.registration(bundleID: bundleID)
        else {
            // LEFT THE BROWSER. An emptied scope is exactly right here: the
            // page is no longer on screen, so nothing in it can be meant.
            retract()
            return
        }

        let pid = front.processIdentifier
        // THE WAKE, AND ITS VERDICT. A Chromium page nobody has asked for
        // publishes no tree, and publishing an empty slate for it would say
        // "this page offers nothing" about a page nobody has looked at yet.
        let readiness = await BrowserAXReadiness.ensureWebContentAX(
            pid: pid, bundleID: bundleID)
        guard readiness != .axTreeAbsent else { return }

        let elements = PageControlsReader.read(inApp: WebSurface.application(pid: pid))
        // NOT AN EMPTY PUBLICATION. A page that genuinely offers nothing and a
        // page that has not finished building read identically here, and only
        // one of them is worth telling the index about.
        guard !elements.isEmpty else { return }

        let place = AmbientPlaceResolver.browserPlace
        let scope = AmbientElementScope.affordances(in: place)

        // SAME PAGE, SAME SLATE. The signature is the labels in order, which
        // is what a phrase resolves against — a scroll that changes frames
        // without changing what is offered is not a new slate.
        let signature = elements.map { "\($0.kind.spokenWord)|\($0.label)" }
        let unchanged = lastBox.withLock { last -> Bool in
            defer { last = (pid, signature) }
            return last?.pid == pid && last?.signature == signature
        }

        let previous = publishedBox.withLock { current -> AmbientElementScope? in
            defer { current = scope }
            return current == scope ? nil : current
        }
        if let previous {
            elementIndex.noteElements([], scope: previous)
        } else if unchanged {
            return
        }

        elementIndex.noteElements(
            AffordanceRule.records(for: Self.affordances(from: elements), scope: scope),
            scope: scope)
    }

    private func retract() {
        lastBox.withLock { $0 = nil }
        let previous = publishedBox.withLock { current -> AmbientElementScope? in
            defer { current = nil }
            return current
        }
        guard let previous else { return }
        elementIndex.noteElements([], scope: previous)
    }

    /// The page's controls as ambient affordances.
    ///
    /// THE ORDINAL IS THE ONE WITHIN ITS KIND, matching what
    /// `list_page_elements` reads aloud — "video 3" has to mean the same
    /// thing whether the model asked for the list or resolved a phrase
    /// against this index, or the two lanes number the same page differently
    /// and one of them presses the wrong thing.
    static func affordances(from elements: [PageElement]) -> [AmbientAffordance] {
        var counters: [PageElementKind: Int] = [:]
        return elements.map { element in
            let next = (counters[element.kind] ?? 0) + 1
            counters[element.kind] = next
            return AmbientAffordance(
                // The reader's own identity spelling, so a record in the
                // index and an element in a fresh read are the same thing.
                id: "\(element.kind.rawValue)|\(element.label)|\(next)",
                label: element.label,
                roleWord: element.kind.spokenWord,
                ordinal: next,
                isEnabled: element.isEnabled,
                help: element.help,
                frame: nil)
        }
    }
}

public enum BrowserSurfaceObserverSupport {
    public static var all: [any MaryObserver] { [BrowserSurfaceObserver.shared] }
}
