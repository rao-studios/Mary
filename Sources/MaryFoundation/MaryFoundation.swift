//
//  MaryFoundation.swift
//  MaryFoundation
//
//  THE SCHEMA LAYER. Pure data: the grammar a Plugin package is written in,
//  the codec and integrity digest that make one tamper-evident, the value
//  envelopes skills exchange, and the geometry types perception speaks in.
//
//  This target depends on nothing — not on AppKit, not on CoreGraphics, not on
//  another Mary target. Two consequences worth stating, because both are load
//  bearing rather than incidental:
//
//  1. A type placed here reaches every other layer with no manifest edit. That
//     is why AXFrame (screen geometry as plain numbers) lives here rather than
//     beside the accessibility engine that produces it — the ambient layer must
//     be able to describe WHERE something is without importing the machinery
//     that looked.
//
//  2. Nothing here can observe, act, or fail at runtime. A declaration either
//     decodes or it does not; a digest either matches or it does not. Every
//     I/O concern belongs to a layer above.
//
//  A NOTE ON THE WORD "PLUGIN". In Mary a Plugin is a declarative package —
//  a `.mary` file under Abilities/ describing an application, its skills, and
//  the recipes that carry them out. It is never Swift code. The compiled
//  providers that satisfy what a Plugin declares are ADAPTERS, and they live
//  in MaryAdapters. This distinction is the reason the schema layer is where
//  the interesting vocabulary lives: a Plugin is data all the way down.
//

import Foundation

/// The namespace for layer-wide constants.
///
/// Deliberately an empty enum rather than a struct: it exists to be a
/// namespace, and an enum with no cases cannot be instantiated by accident.
public enum MaryFoundation {

    /// The wire format identifier every Plugin package carries.
    ///
    /// Present in the envelope so a reader can reject a file that merely ends
    /// in `.mary` before trusting a single other field.
    public static let packageFormat = "mary.ability-package"

    /// The current format version. A package declaring a higher version than
    /// this build understands is refused rather than partially read.
    public static let packageFormatVersion = 1

    /// The file extension a Plugin package is written to.
    public static let packageFileExtension = "mary"
}
