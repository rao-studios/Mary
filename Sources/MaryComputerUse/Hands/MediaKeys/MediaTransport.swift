//
//  MediaTransport.swift
//  MaryComputerUse
//
//  WHAT: System media keys (NSSystemDefined), app-agnostic.
//  PIN:  Not a chord. Goes to whoever holds now-playing, not the named app.

import AppKit
import Foundation

public enum MediaTransport {

    /// The system-defined key types this build drives. Raw values are Apple's
    /// `NX_KEYTYPE_*` constants from `IOKit/hidsystem/ev_keymap.h`, spelled here because
    /// importing that header for eight integers would drag the whole HID system into a
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

    /// Post one media key as a down/up pair. False when the event could not be constructed
    /// — never a claim about what any application did with it, the same honesty.
    @discardableResult
    public static func post(_ key: Key) -> Bool {
        guard AXIsProcessTrusted() else {
            ComputerUseMonitor.shared.note(lane: .mediaKeys, refused: "mediaKey", reason: .accessibilityUntrusted)
            return false
        }
        guard event(key, down: true), event(key, down: false) else {
            ComputerUseMonitor.shared.note(lane: .mediaKeys, refused: "mediaKey", reason: .eventNotCreated)
            return false
        }
        ComputerUseMonitor.shared.note(lane: .mediaKeys, act: "mediaKey", detail: "\(key)")
        return true
    }

    private static func event(_ key: Key, down: Bool) -> Bool {
        // `data1` packs the key type in its high sixteen bits and the state in its low
        // ones; the modifier flags repeat the state because the window server reads it from
        // both.
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
