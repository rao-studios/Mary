//
//  Totems.swift
//  Mary
//
//  The fifth pane: what the totem fleet holds, and what retrieval did with it.
//
//  It exists because the knowledge-graph store and the retrieval path are
//  write-only or discarded from the UI's point of view — deposits vanish into
//  Totem's plists, the resolved scope and the returned contribution are
//  computed and dropped, and the entity graph never comes back out. Without a
//  window onto them the retrieval paradigm is a black box that either answers
//  well or does not, with no way to find out which.
//
//  Granite components are plain Views (`@Command` rides a `@StateObject`), so
//  insertion builds a fresh center and removal tears it down; nothing here
//  assumes root-ness — which is what makes the bare `if` in the split safe.
//

import Granite
import SwiftUI

struct Totems: GraniteComponent {
    @Command var center: Center
}
