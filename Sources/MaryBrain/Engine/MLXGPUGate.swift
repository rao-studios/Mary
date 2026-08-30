//
//  MLXGPUGate.swift
//  MaryBrain
//
//  One generation at a time on the local GPU. Conversation and coding
//  engines both wait here so two models never decode together. Acquire and
//  release hop onto this actor; the generate itself stays on the engine that
//  holds ModelContext.
//

import Foundation

actor MLXGPUGate {
    static let shared = MLXGPUGate()

    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if held {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiters.append(continuation)
            }
        }
        held = true
    }

    func release() {
        if waiters.isEmpty {
            held = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
