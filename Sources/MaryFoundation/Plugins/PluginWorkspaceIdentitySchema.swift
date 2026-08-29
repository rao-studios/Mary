//
//  PluginWorkspaceIdentitySchema.swift
//  MaryFoundation
//
//  HOW THIS APPLICATION NAMES ITS PROJECT ROOT AND FOCUSED FILE — declared,
//  not measured against one editor.
//
//  CorpusObserver first learned these facts against one IDE: `AXDocument`
//  is sometimes the folder and sometimes the open file, and the focused
//  file's name rides the window title after an em dash. That is true of
//  THAT editor. A second code editor — or a manuscript app — may put the
//  root on a different attribute and split the title differently. Those
//  differences belong on the application package so a later similar app
//  is taught by JSON, never by a new `if` in the observer.
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
    /// Empty means the title is not used; the focused file is `AXDocument`
    /// itself when `rootSource` is `.documentFile`.
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

    /// The focused file's basename from a window title, or nil when this
    /// identity does not parse titles or the title does not carry a file.
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
