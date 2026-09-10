//
//  Threads.swift
//  Mary
//
//  WHAT: Fifth pane — fleet holdings and what retrieval did with them.
//  IN:   Home+View (bare `if` split child)
//  OUT:  Threads+View / ThreadsPaneView
//  PIN:  Store and retrieval are write-only from the UI; this is the read window.
//

import Granite
import SwiftUI

struct Threads: GraniteComponent {
    @Command var center: Center
}
