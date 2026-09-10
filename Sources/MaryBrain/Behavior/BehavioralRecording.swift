//
//  BehavioralRecording.swift
//  MaryBrain
//
//  WHAT: Where a sealed episode goes.
//  IN:   BehavioralAssembler.seal
//  OUT:  Thread deposit / test collector
//  PIN:  Brain never learns about Thread; runtime injects.
//
import Foundation
import MaryFoundation

public protocol BehavioralRecording: Sendable {
    /// Called once per sealed episode, in seal order.
    /// PIN: NOT THROWING, and not async-failing in a way the brain can see.
    func append(_ episode: BehavioralEpisode) async
}
