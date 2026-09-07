//
//  CanvasModels.swift
//  MaryPlugin
//
//  WHAT: What the canvas shows, where, and what it says afterwards.
//  IN:   CanvasService / CanvasPlugin / any package that presents a page
//  OUT:  CanvasPage, CanvasPlacement, CanvasWindowID, CanvasReceipt, CanvasRefusal
//  PIN:  A PAGE IS A MESSAGE, NOT A PLACE. It lives in memory, is shown whole,
//        and nothing on it is crawled, indexed or acted on. The page's one
//        channel back is `ready` — whether what it meant to draw is drawn.
//

import CoreGraphics
import Foundation

/// One page Mary draws in a window of her own. The HTML is whole and in
/// memory; it is never written to disk.
public struct CanvasPage: Sendable, Equatable {
    public var title: String
    public var html: String

    public init(title: String, html: String) {
        self.title = title
        self.html = html
    }

    /// Bytes of UTF-8, the size the canvas refuses past.
    public var byteCount: Int { html.utf8.count }
}

/// Where on the screen a page goes.
public enum CanvasPlacement: Sendable, Equatable {
    /// The whole screen.
    case fullScreen
    /// A centred window, 60 % of the screen on each side.
    case panel
    /// An exact frame, in screen coordinates.
    case rect(CGRect)

    /// The frame this placement means on a screen of `screen`.
    public func frame(on screen: CGRect) -> CGRect {
        switch self {
        case .fullScreen:
            return screen
        case .panel:
            let size = CGSize(width: screen.width * 0.6, height: screen.height * 0.6)
            return CGRect(
                x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
                width: size.width, height: size.height)
        case .rect(let rect):
            return rect
        }
    }

    /// A centred window `fraction` of the screen on each side — what a page
    /// that must not be the monitor itself asks for.
    public static func centered(_ fraction: Double, on screen: CGRect) -> CanvasPlacement {
        let f = min(max(fraction, 0.1), 0.95)
        let size = CGSize(width: screen.width * f, height: screen.height * f)
        return .rect(CGRect(
            x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
            width: size.width, height: size.height))
    }

    /// The model-facing spelling, when there is one.
    public init?(spoken: String) {
        switch spoken.lowercased().replacingOccurrences(of: "-", with: "_") {
        case "full_screen", "fullscreen", "full": self = .fullScreen
        case "panel", "window": self = .panel
        default: return nil
        }
    }
}

/// The one identity a canvas window keeps.
public struct CanvasWindowID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { String(rawValue.uuidString.prefix(8)) }
}

/// What a page said once it was loaded — or that it said nothing in time.
public struct CanvasReceipt: Sendable, Equatable {
    public var id: CanvasWindowID
    /// The page reported that what it meant to draw is drawn.
    public var ready: Bool
    /// The page's own words about why not, when it had any.
    public var log: String?
    /// The page never reported within the bound; `ready` is false and this
    /// says so, because a silent page and a failed page read differently.
    public var timedOut: Bool

    public init(id: CanvasWindowID, ready: Bool, log: String? = nil, timedOut: Bool = false) {
        self.id = id
        self.ready = ready
        self.log = log
        self.timedOut = timedOut
    }
}

/// Why the canvas would not, in a sentence a person can act on.
public enum CanvasRefusal: Error, Sendable, Equatable {
    case noScreen
    case pageTooLarge(bytes: Int)
    case pageNotReady(log: String?)
    case stageHeld(owner: String)
    case nothingShowing
    case unknownWindow

    public static let pageByteLimit = 512 * 1024

    public var summary: String {
        switch self {
        case .noScreen:
            return "There's no screen to draw on."
        case .pageTooLarge(let bytes):
            return "That page is \(bytes / 1024) KB — the canvas takes pages under \(Self.pageByteLimit / 1024) KB."
        case .pageNotReady(let log):
            if let log, !log.isEmpty { return "The page didn't come up: \(log)" }
            return "The page never said it was ready."
        case .stageHeld(let owner):
            return "The stage is held by \(owner) — I couldn't put a page up."
        case .nothingShowing:
            return "Nothing's showing."
        case .unknownWindow:
            return "That page is already gone."
        }
    }
}

/// How a window left the screen.
public enum CanvasDismissal: Sendable, Equatable {
    /// The caller — a Skill or a plugin — took it down.
    case caller
    /// The person clicked it.
    case click
    /// Another stage Skill needed the screen.
    case preempt
}
