//
//  SchemaIssue.swift
//  MaryFoundation
//
//  WHAT: One admission finding plus the set verdict.
//  IN:   PackageIssueSink / PluginValidator.
//  OUT:  AbilityPackageValidation.isValid (error refuses; warning is a note).
//

import Foundation

public enum SchemaIssueSeverity: String, Codable, Hashable, Sendable, CaseIterable {
    case warning
    case error
}

public struct SchemaIssue: Codable, Hashable, Sendable, Identifiable {
    public var severity: SchemaIssueSeverity
    public var code: String
    public var path: String
    public var message: String

    public init(severity: SchemaIssueSeverity, code: String, path: String, message: String) {
        self.severity = severity
        self.code = code
        self.path = path
        self.message = message
    }

    public var id: String { "\(severity.rawValue):\(code):\(path):\(message)" }
}

public struct AbilityPackageValidation: Codable, Hashable, Sendable {
    public var issues: [SchemaIssue]
    public var isValid: Bool { !issues.contains { $0.severity == .error } }

    public init(issues: [SchemaIssue] = []) { self.issues = issues }
}
