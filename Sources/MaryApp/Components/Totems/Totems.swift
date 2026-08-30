//
//  Totems.swift
//  Mary
//
//  WHAT: Fifth pane — fleet holdings and what retrieval did with them.
//  IN:   Home+View (bare `if` split child)
//  OUT:  Totems+View / TotemsPaneView
//  PIN:  Store and retrieval are write-only from the UI; this is the read window.
//

import Granite
import SwiftUI

struct Totems: GraniteComponent {
    @Command var center: Center
}
