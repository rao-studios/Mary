//
//  DeclaredTextHandoff.swift
//  MaryPlugin
//
//  WHAT: SelectionHandoff specialist for a declared text surface.
//  IN:   DeclaredTextAX  OUT: SelectionHandoffPublisher
//  PIN:  Subject is the document, never the app display name.
//

import AppKit
import ApplicationServices
import Foundation
import MaryAmbient
import MaryComputerUse

public enum DeclaredTextHandoff {

    public static func capture<R: DeclaredTextSurface & SurfaceClaim>(
        registration: R,
        trigger: SelectionHandoffCoordinator.CaptureTrigger,
        ambient: AmbientContextStore
    ) -> SelectionHandoffCoordinator.CaptureOutcome {
        guard let pid = SurfacePollTarget.pid(
            of: registration, running: SurfacePollTarget.runningProcesses())
        else { return .noEvidence }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, DeclaredTextAX.messagingTimeout)
        guard let window = AX.element(application, kAXFocusedWindowAttribute),
              let editor = CodeSurfaceEditorCache.editor(
                pid: pid, window: window, registration: registration),
              let range = DeclaredTextAX.selectedRange(of: editor),
              !range.isEmpty,
              let text = DeclaredTextAX.substring(of: editor, range: range),
              !text.isEmpty
        else { return .noEvidence }

        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            ?? registration.applicationID
        let sample = AXSelectionReader.FocusedSelectionSample(
            processID: pid,
            state: .selected(.init(
                text: text,
                range: range,
                extraction: .characterRange)),
            capturedAt: Date(),
            sourceCharacterCount: DeclaredTextAX.characterCount(of: editor),
            editability: .editable,
            sourceEvidence: .exactElement)
        return SelectionHandoffPublisher.captureOutcome(
            sample,
            ambient: ambient,
            place: AmbientPlace.application(registration.applicationID),
            applicationID: bundleID,
            subject: DeclaredTextAX.documentSubject(of: window),
            channel: .sourcePoll,
            clearCaret: trigger == .activeSourcePreflight)
    }

    public static func register<R: DeclaredTextSurface & SurfaceClaim>(
        _ registrations: [R],
        bundleIdentifiers: (R) -> [String],
        familyPrefix: (R) -> String? = { _ in nil },
        ambient: AmbientContextStore
    ) -> [UUID] {
        var tokens: [UUID] = []
        for registration in registrations {
            for bundleID in bundleIdentifiers(registration) {
                tokens.append(
                    SelectionHandoffCoordinator.shared.register(applicationID: bundleID) { trigger in
                        capture(
                            registration: registration, trigger: trigger, ambient: ambient)
                    })
            }
            if let prefix = familyPrefix(registration), !prefix.isEmpty {
                tokens.append(
                    SelectionHandoffCoordinator.shared.register(
                        applicationFamilyPrefix: prefix
                    ) { trigger in
                        capture(
                            registration: registration, trigger: trigger, ambient: ambient)
                    })
            }
        }
        return tokens
    }

    public static func unregister(_ tokens: [UUID]) {
        for token in tokens {
            SelectionHandoffCoordinator.shared.unregister(token)
        }
    }
}
