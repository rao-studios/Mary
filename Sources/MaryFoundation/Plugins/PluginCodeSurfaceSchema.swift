//
//  PluginCodeSurfaceSchema.swift
//  MaryFoundation
//
//  WHAT: Live code-buffer coordinates. Read-only sibling of PluginProseSurfaceSchema.
//  IN:   PluginSchema.codeSurface.
//  OUT:  generic code-surface reader; PluginValidator+CodeSurface.
//  PIN:  No write half, grammar, chords, watch, documentNoun.
//

import Foundation

/// The declared coordinates of one application's live code buffer.
public struct PluginCodeSurfaceSchema: Codable, Hashable, Sendable {

    /// Spoken-handle letter. Same namespace as prose; PluginGraphValidator checks both.
    public var handlePrefix: String

    /// Roles in preference order. Focused match vs largest; exact role, not "text-shaped".
    public var editorRoles: [PluginAccessibilityRole]

    /// How a document in this application earns a stable name across polls.
    public var documentKey: PluginProseDocumentKey

    /// How much text may be taken at once.
    public var budgets: PluginProseBudgetSchema

    /// Same identity as the corpus observer (editor may omit a corpus).
    public var workspaceIdentity: PluginWorkspaceIdentitySchema

    /// Focused declared-role wins (split pane). False = largest-wins.
    public var preferFocusedElement: Bool

    public init(
        handlePrefix: String,
        editorRoles: [PluginAccessibilityRole] = [.textArea],
        documentKey: PluginProseDocumentKey = .documentPathThenWindow,
        budgets: PluginProseBudgetSchema = .init(),
        workspaceIdentity: PluginWorkspaceIdentitySchema = .default,
        preferFocusedElement: Bool = true
    ) {
        self.handlePrefix = handlePrefix
        self.editorRoles = editorRoles
        self.documentKey = documentKey
        self.budgets = budgets
        self.workspaceIdentity = workspaceIdentity
        self.preferFocusedElement = preferFocusedElement
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case handlePrefix
        case editorRoles
        case documentKey
        case budgets
        case workspaceIdentity
        case preferFocusedElement
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        handlePrefix = try values.decode(String.self, forKey: .handlePrefix)
        editorRoles = try values.decodeIfPresent(
            [PluginAccessibilityRole].self, forKey: .editorRoles) ?? [.textArea]
        documentKey = try values.decodeIfPresent(
            PluginProseDocumentKey.self, forKey: .documentKey) ?? .documentPathThenWindow
        budgets = try values.decodeIfPresent(
            PluginProseBudgetSchema.self, forKey: .budgets) ?? .init()
        workspaceIdentity = try values.decodeIfPresent(
            PluginWorkspaceIdentitySchema.self, forKey: .workspaceIdentity) ?? .default
        preferFocusedElement = try values.decodeIfPresent(
            Bool.self, forKey: .preferFocusedElement) ?? true
    }

    /// Hand-written CodingKeys — digest is these bytes.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(handlePrefix, forKey: .handlePrefix)
        try container.encode(editorRoles, forKey: .editorRoles)
        try container.encode(documentKey, forKey: .documentKey)
        try container.encode(budgets, forKey: .budgets)
        if workspaceIdentity != .default {
            try container.encode(workspaceIdentity, forKey: .workspaceIdentity)
        }
        if !preferFocusedElement {
            try container.encode(preferFocusedElement, forKey: .preferFocusedElement)
        }
    }
}
