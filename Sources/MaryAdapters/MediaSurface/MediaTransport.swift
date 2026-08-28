//
//  MediaTransport.swift
//  MaryAdapters
//
//  MARY'S HANDS FOR PLAYBACK — the system media keys, posted the way
//  `KeyChordPress` posts a chord, and app-agnostic on purpose.
//
//  WHY MEDIA KEYS AND NOT THE PLAYER'S OWN SHORTCUTS. Apple Music answers
//  Space for play/pause — but only while it is frontmost, so a chord road
//  means STEALING THE USER'S FOCUS to pause a song. That is a bad trade for
//  the most common request anyone makes of a music player, and it is worse
//  than it sounds: the typer's whole stage-lease apparatus exists because
//  driving focus mid-sentence loses keystrokes. A media key needs no
//  frontmost application and moves nothing on screen.
//
//  THE PRICE, STATED PLAINLY. A media key goes to whatever macOS considers
//  the current now-playing application, which is not necessarily the one the
//  user named. Asking to "pause Music" while a browser video has the media
//  role pauses the video. Mary cannot see who holds that role — the framework
//  that answers is private and entitlement-gated on this OS — so the honest
//  design is: transport verbs are addressed to THE PLAYER, singular, and the
//  spoken summary says which player Mary could actually see running rather
//  than claiming to have driven a named one.
//
//  NOT A CHORD, MECHANICALLY. These are `NSSystemDefined` subtype-8 events
//  rather than keyboard events, so `KeyChordPress` cannot express them and
//  the recipe grammar has no step for them. That is precisely why this is a
//  compiled adapter and not a declaration: a package can say WHICH verb it
//  wants, and this posts it.
//

import AppKit
import Foundation

public enum MediaTransport {

    /// The system-defined key types this build drives. Raw values are Apple's
    /// `NX_KEYTYPE_*` constants from `IOKit/hidsystem/ev_keymap.h`, spelled
    /// here because importing that header for eight integers would drag the
    /// whole HID system into a target that needs nothing else from it.
    public enum Key: Int32, Sendable, CaseIterable {
        case soundUp = 0
        case soundDown = 1
        case mute = 7
        case playPause = 16
        case next = 17
        case previous = 18
        case fastForward = 19
        case rewind = 20
    }

    /// Post one media key as a down/up pair.
    ///
    /// False when the event could not be constructed — never a claim about
    /// what any application did with it, the same honesty `KeyChordPress`
    /// keeps. There is no acknowledgement to wait for: the key goes to the
    /// system, and whether a player moved is a question for the next read.
    @discardableResult
    public static func post(_ key: Key) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        return event(key, down: true) && event(key, down: false)
    }

    private static func event(_ key: Key, down: Bool) -> Bool {
        // THE SHAPE IS THE PROTOCOL. `data1` packs the key type in its high
        // sixteen bits and the state in its low ones; the modifier flags
        // repeat the state because the window server reads it from both. The
        // magic numbers are Apple's, and getting either half wrong produces
        // an event that is accepted and ignored — which is why this is one
        // function rather than a shape spelled at each call site.
        let state = down ? 0x0A00 : 0x0B00
        let flags = NSEvent.ModifierFlags(rawValue: UInt(state))
        let data1 = Int((key.rawValue << 16) | Int32(state))
        guard let nsEvent = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1),
            let event = nsEvent.cgEvent
        else { return false }
        // HID level, for the reason `KeyChordPress` gives: a session-level tap
        // is filtered by applications that guard against synthetic input.
        event.post(tap: .cghidEventTap)
        return true
    }
}
