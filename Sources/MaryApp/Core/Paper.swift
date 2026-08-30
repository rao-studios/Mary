//
//  Paper.swift
//  Mary
//
//  WHAT: Page palette. Views resolve color here, never raw RGB. Light-locked (Fleet).
//

import SwiftUI

enum Paper {
    /// The page itself — warm white.
    static let page = Color(red: 253 / 255, green: 251 / 255, blue: 244 / 255)

    /// Ink accents that must not fade with `.primary` opacity (strokes, icons).
    static let ink = Color(red: 20 / 255, green: 20 / 255, blue: 14 / 255)

    /// Interaction pigments.
    static let highlight = Color(red: 250 / 255, green: 224 / 255, blue: 120 / 255)
    static let graphite = Color(red: 120 / 255, green: 118 / 255, blue: 110 / 255)

    /// Reading measure — passages never grow wider than this.
    static let measure: CGFloat = 460
}
