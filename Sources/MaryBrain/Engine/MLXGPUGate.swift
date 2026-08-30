//
//  MLXGPUGate.swift
//  MaryBrain
//
//  WHAT: One local-GPU generation at a time.
//  IN:   conversation + coding engines
//  OUT:  acquire / release; generate stays on the engine that holds ModelContext
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
