//
//  Corpus.swift
//  Mary
//
//  WHAT: Fourth pane — what indexing ingested, concluded, and did.
//  IN:   Home+View (bare `if` split child)
//  OUT:  Corpus+View / CorpusPaneView
//  PIN:  Pipeline is write-only; this is the read window. Fresh Center on insert.
//

import Granite
import SwiftUI

struct Corpus: GraniteComponent {
    @Command var center: Center
}
