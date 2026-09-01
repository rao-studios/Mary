//
//  HandleMap.swift
//  MaryBrain
//
//  WHAT: Session-stable short handles ("E1", "R2", "P3") for entity identifiers.
//  IN:   ContainerRegistry.State / PassageRegistry.State
//  OUT:  LLM conversation (never the long id)
//  PIN:  Each plugin owns a map with its own prefix letter.
//
import Foundation

// `Sendable` IS SPELLED OUT because this type is `public`.
public struct HandleMap: Sendable {
    public let prefix: String
    private var byIdentifier: [String: String] = [:]
    private var byHandle: [String: String] = [:]
    private var counter = 0

    public init(prefix: String) {
        self.prefix = prefix
    }

    /// Mint (or reuse) the handle for an identifier.
    public mutating func handle(for identifier: String) -> String {
        if let existing = byIdentifier[identifier] { return existing }
        counter += 1
        let handle = "\(prefix)\(counter)"
        byIdentifier[identifier] = handle
        byHandle[handle.lowercased()] = identifier
        return handle
    }

    /// Resolve tolerantly: "E1" / "e1" / " E1 " / "[E1]" all work; a raw
    /// identifier (long, or containing ":") passes through unchanged.
    public func identifier(forHandle raw: String) -> String? {
        let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: " []"))
        if cleaned.contains(":") || cleaned.count > 8 {
            return cleaned
        }
        return byHandle[cleaned.lowercased()]
    }
}
