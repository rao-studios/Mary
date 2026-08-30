//
//  PluginProjectBuildSchema.swift
//  MaryFoundation
//
//  WHAT: Declared CLI for build/test. Absent → backend from projectMarkers.
//  IN:   PluginCorpusSchema.build.
//  OUT:  generic build adapter at project root.
//

import Foundation

public struct PluginProjectBuildSchema: Codable, Hashable, Sendable {
    /// Executable plus args at project root. Empty → pick from markers.
    public var checkCommand: [String]
    public var testCommand: [String]
    /// Extra arguments appended when the user names a filter (a test).
    public var testFilterFlag: String?

    public init(
        checkCommand: [String] = [],
        testCommand: [String] = [],
        testFilterFlag: String? = nil
    ) {
        self.checkCommand = checkCommand
        self.testCommand = testCommand
        self.testFilterFlag = testFilterFlag
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case checkCommand
        case testCommand
        case testFilterFlag
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        checkCommand = try values.decodeIfPresent([String].self, forKey: .checkCommand) ?? []
        testCommand = try values.decodeIfPresent([String].self, forKey: .testCommand) ?? []
        testFilterFlag = try values.decodeIfPresent(String.self, forKey: .testFilterFlag)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !checkCommand.isEmpty {
            try container.encode(checkCommand, forKey: .checkCommand)
        }
        if !testCommand.isEmpty {
            try container.encode(testCommand, forKey: .testCommand)
        }
        if let testFilterFlag {
            try container.encode(testFilterFlag, forKey: .testFilterFlag)
        }
    }
}
