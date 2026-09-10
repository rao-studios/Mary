//
//  PluginWorkspaceIdentitySchema.swift
//  MaryFoundation
//
//  WHAT: How this app names project root and focused file (declared, not one-IDE).
//  IN:   PluginCorpusSchema.workspaceIdentity.
//  OUT:  CorpusObserver.
//

import Foundation

/// Where the project root is read from, and how the focused file is named.
public struct PluginWorkspaceIdentitySchema: Codable, Hashable, Sendable {

    /// How `AXDocument` on the focused window relates to the project root.
    public enum RootSource: String, Codable, Hashable, Sendable, CaseIterable {
        /// The attribute is a folder when a project is open.
        case documentDirectory
        /// The attribute is the focused file; climb to a declared marker.
        case documentFile
        /// Folder if the path is a directory, otherwise climb from the file.
        case documentAuto
    }

    /// Which piece of a split window title is the focused file's name.
    public enum TitlePart: String, Codable, Hashable, Sendable, CaseIterable {
        case first
        case last
    }

    public var rootSource: RootSource
    /// Empty = ignore title; focused file is AXDocument when `.documentFile`.
    public var focusedFileTitleSeparator: String
    public var focusedFileTitlePart: TitlePart

    public static let `default` = PluginWorkspaceIdentitySchema(
        rootSource: .documentAuto,
        focusedFileTitleSeparator: " — ",
        focusedFileTitlePart: .last)

    public init(
        rootSource: RootSource = .documentAuto,
        focusedFileTitleSeparator: String = " — ",
        focusedFileTitlePart: TitlePart = .last
    ) {
        self.rootSource = rootSource
        self.focusedFileTitleSeparator = focusedFileTitleSeparator
        self.focusedFileTitlePart = focusedFileTitlePart
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case rootSource
        case focusedFileTitleSeparator
        case focusedFileTitlePart
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        rootSource = try values.decodeIfPresent(
            RootSource.self, forKey: .rootSource) ?? .documentAuto
        focusedFileTitleSeparator = try values.decodeIfPresent(
            String.self, forKey: .focusedFileTitleSeparator) ?? " — "
        focusedFileTitlePart = try values.decodeIfPresent(
            TitlePart.self, forKey: .focusedFileTitlePart) ?? .last
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if rootSource != .documentAuto {
            try container.encode(rootSource, forKey: .rootSource)
        }
        if focusedFileTitleSeparator != " — " {
            try container.encode(
                focusedFileTitleSeparator, forKey: .focusedFileTitleSeparator)
        }
        if focusedFileTitlePart != .last {
            try container.encode(focusedFileTitlePart, forKey: .focusedFileTitlePart)
        }
    }

    /// Focused-file basename from title, or nil.
    public func focusedFileName(inTitle title: String) -> String? {
        let separator = focusedFileTitleSeparator
        guard !separator.isEmpty else { return nil }
        let parts = title.components(separatedBy: separator)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard parts.count >= 2 else { return nil }
        let name = focusedFileTitlePart == .first ? parts.first : parts.last
        return name.flatMap { $0.isEmpty ? nil : $0 }
    }
}
