//
//  PackageFixtures.swift
//  MaryFoundationTestSupport
//
//  WHAT: MaryAbilityPackage builders. Codec computes digest; tests name the shape.
//  IN:   AbilityPackageCodec.
//  OUT:  Tests/ (shared across test targets — this is not a test target).
//

import Foundation
import MaryFoundation

public enum PackageFixtures {

    /// Minimal valid package: one discipline, one cognitive Skill, no Plugin.
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

    /// Application-expertise fixture: one chord, prose surface, workspace claim.
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

    /// Well-formed prose surface for single-field breakage.
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

    /// Well-formed code surface for single-field breakage.
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
