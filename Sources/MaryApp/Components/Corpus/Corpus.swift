//
//  Corpus.swift
//  Mary
//
//  The fourth pane: what indexing ingested, what it concluded, and what it did.
//
//  It exists because the indexing pipeline is write-only by construction — an
//  `IndexedUnit` is destroyed at the sink, the manifest keeps three fields, and
//  Totem returns neither tags nor metadata nor the entity graph. Without a
//  window onto it the profile is a black box that either feels right or does
//  not, with no way to find out which.
//
//  Granite components are plain Views (`@Command` rides a `@StateObject`), so
//  insertion builds a fresh center and removal tears it down; nothing here
//  assumes root-ness — which is what makes the bare `if` in the split safe.
//

import Granite
import SwiftUI

struct Corpus: GraniteComponent {
    @Command var center: Center
}
