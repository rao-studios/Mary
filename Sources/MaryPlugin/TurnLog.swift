//
//  TurnLog.swift
//  MaryPlugin
//
//  WHAT: Console logger for the Xcode / pair-coding turn circuit.
//  OUT:  Console.app category "turns" (same filter as MaryBrain.turnLog)
//

import os

enum TurnLog {
    static let logger = Logger(subsystem: "nyc.rao.mary", category: "turns")
}
