//
//  PackageFixtures.swift
//  MaryFoundationTestSupport
//
//  PACKAGES BUILT IN SWIFT, SO TESTS CAN SAY WHAT THEY MEAN.
//
//  A `.mary` file is one JSON document with a digest over its canonical bytes,
//  which makes it exactly the wrong thing to hand-edit in a test: change one
//  field and the digest is stale, and a test that recomputes the digest is no
//  longer testing the digest. So fixtures are BUILT — a test names the shape it
//  needs, the codec computes the bytes, and the two stay honest with each
//  other.
//
//  A NON-TEST TARGET, deliberately. A test target cannot expose declarations to
//  another test target, and these fixtures are needed by more than one.
//
//  WHAT LIVES HERE VERSUS WHAT SHIPS. This file builds the smallest package
//  that can be valid, plus the knobs a validation test needs to make it
//  invalid in one specific way. The real shipped packages — writing,
//  window-management, textedit — are built by their own files alongside this
//  one, and `Abilities/*.mary` is regenerated from them.
//

import Foundation
import MaryFoundation

public enum PackageFixtures {

    /// The smallest package the validator admits: one discipline Ability, one
    /// cognitive Skill, no Plugin.
    ///
    /// Every test that needs "a valid package" starts here and mutates the one
    /// field it is about, so a failure names one cause rather than a soup.
    public static var minimalDiscipline: MaryAbilityPackage {
        MaryAbilityPackage(
            package: .init(
                id: "tests.minimal",
                version: "1.0.0",
                publisher: "Mary tests",
                summary: "The smallest package that validates."),
            ability: .init(
                id: "tests.minimal",
                title: "Minimal",
                summary: "A discipline with one thought and no hands.",
                tint: "#808080",
                skills: ["tests.minimal.think"],
                paradigm: .discipline),
            skills: [
                SkillSchema(
                    id: "tests.minimal.think",
                    title: "Think",
                    summary: "Consider something and say what you concluded.",
                    kind: .cognitive,
                    execution: .init(kind: .cognitive),
                    modelExposure: .init(invocationName: "think"))
            ])
    }

    /// A package that teaches Mary one application: identity, one chord
    /// operation realizing one Skill, and a prose surface behind a workspace
    /// perception claim.
    ///
    /// Shaped like `textedit.mary` without being it — a fictional bundle id, so
    /// a test can break this in ways nobody would want done to a shipped
    /// package.
    public static var applicationExpertise: MaryAbilityPackage {
        MaryAbilityPackage(
            package: .init(
                id: "tests.editor",
                version: "1.0.0",
                publisher: "Mary tests",
                summary: "Expertise in a fictional text editor."),
            ability: .init(
                id: "tests.editor",
                title: "Test Editor",
                summary: "Knows one fictional editor's chords and where it keeps text.",
                tint: "#4A6FA5",
                skills: ["tests.editor.save"],
                paradigm: .applicationExpertise),
            skills: [
                SkillSchema(
                    id: "tests.editor.save",
                    title: "Save the document",
                    summary: "Write the front document to disk.",
                    kind: .effectful,
                    access: .reversible,
                    requirements: .init(capabilities: ["tests.editor.save"]),
                    execution: .init(
                        kind: .binding,
                        realizationPolicy: .pluginRealizations),
                    modelExposure: .init(invocationName: "save_document"),
                    usesStage: true)
            ],
            capabilities: [
                CapabilitySchema(
                    id: "tests.editor.save",
                    title: "Save a document",
                    summary: "Issue this editor's save chord.",
                    effect: .reversibleMutation,
                    permissions: [.init(kind: .accessibility, reason: "Issues a key chord.")],
                    constraints: [.init(kind: .requiresStage, value: "true")])
            ],
            plugin: PluginSchema(
                id: "tests.editor",
                title: "Test Editor",
                application: .init(
                    id: "tests.editor",
                    title: "Test Editor",
                    bundleIdentifiers: ["com.example.testeditor"],
                    targetClasses: ["editable-prose-surface"],
                    activation: .activateRunning,
                    perception: .init(kind: .workspace)),
                adapter: .init(
                    id: "tests.editor.managed-ui",
                    title: "Test Editor managed UI",
                    engine: .macUI,
                    permissions: [.accessibility]),
                operations: [
                    .init(
                        operation: "test_editor_save",
                        title: "Save",
                        summary: "Press the save chord and let the write settle.",
                        adapterID: "tests.editor.managed-ui",
                        steps: [
                            .init(id: "save", kind: .keyChord, key: .s, modifiers: [.command]),
                            .init(id: "settle", kind: .wait, durationSeconds: 0.35),
                        ],
                        postconditions: [.applicationFrontmost])
                ],
                realizations: [
                    .init(
                        skillID: "tests.editor.save",
                        operation: "test_editor_save",
                        preference: 200,
                        targetClasses: ["editable-prose-surface"])
                ],
                proseSurface: proseSurface))
    }

    /// A well-formed prose-surface declaration, for tests that break one field
    /// of it at a time.
    public static var proseSurface: PluginProseSurfaceSchema {
        PluginProseSurfaceSchema(
            handlePrefix: "W",
            editorRoles: [.textArea],
            grammar: .prose,
            documentKey: .documentPathThenWindow,
            documentNoun: .init(singular: "note", plural: "notes"),
            chords: [.newDocument: .init(key: .n, modifiers: [.command])],
            watch: .init(activeSeconds: 2.5, idleSeconds: 10),
            budgets: .init(
                wholeDocumentCharacters: 3600,
                regionCharacters: 1800,
                ambientExcerptCharacters: 280))
    }

    /// A well-formed code-surface declaration, `proseSurface`'s sibling for
    /// tests that break one field of it at a time.
    public static var codeSurface: PluginCodeSurfaceSchema {
        PluginCodeSurfaceSchema(
            handlePrefix: "C",
            editorRoles: [.textArea],
            documentKey: .documentPathThenWindow,
            budgets: .init(
                wholeDocumentCharacters: 20000,
                regionCharacters: 4000,
                ambientExcerptCharacters: 500))
    }
}
