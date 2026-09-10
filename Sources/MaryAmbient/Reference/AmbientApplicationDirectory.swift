//
//  AmbientApplicationDirectory.swift
//  MaryBrain
//
//  WHAT: Session-scoped bundle ID → human name.
//  IN:   activations (localizedName)
//  OUT:  AmbientPlace.displayName
//  PIN:  Generic-application places identity is the bundle ID (stable for
//        clearLead / termination); the chip must not show the raw id.
//
import Foundation
import os

public final class AmbientApplicationDirectory: @unchecked Sendable {

    public static let shared = AmbientApplicationDirectory()

    private let box = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    public init() {}

    public func note(bundleID: String, name: String?) {
        guard let name, !name.isEmpty else { return }
        box.withLock { $0[bundleID] = name }
    }

    public func name(for bundleID: String) -> String? {
        box.withLock { $0[bundleID] }
    }

    /// App terminated — the identity may be reused by a different version
    /// next launch; the name re-records on the next activation anyway.
    public func evict(bundleID: String) {
        box.withLock { $0[bundleID] = nil }
    }
}
