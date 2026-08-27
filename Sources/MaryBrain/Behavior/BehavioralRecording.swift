//
//  BehavioralRecording.swift
//  MaryBrain
//
//  WHERE A SEALED EPISODE GOES. One method, because the brain has exactly one
//  thing to say to a store: here is a finished turn.
//
//  AN ABSTRACTION AND NOT A CLASS, so the brain never learns about files. The
//  runtime injects a JSONL store; a test injects an array; a build with
//  recording switched off injects nothing at all and the assembler seals into
//  the void without a single `if` at the call sites.
//

import Foundation
import MaryFoundation

public protocol BehavioralRecording: Sendable {
    /// Called once per sealed episode, in seal order.
    ///
    /// NOT THROWING, and not async-failing in a way the brain can see. A turn
    /// that succeeded must not be reported as failed because a disk was full;
    /// the store's job is to lose the row loudly in its own log, not to fail
    /// the act it describes.
    func append(_ episode: BehavioralEpisode) async
}
