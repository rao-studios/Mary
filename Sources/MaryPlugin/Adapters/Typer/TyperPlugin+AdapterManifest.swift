//
//  TyperPlugin+AdapterManifest.swift
//  MaryBrain
//
//  WHAT: Writing Ability machine contract.
//  IN:   TyperPlugin
//  OUT:  InstalledAdapterManifest
//  PIN:  Adapter owns execution; `.mary` package owns routing. Empty claims fail closed.
//

import AppKit
import Foundation
import os

extension TyperPlugin {


    /// Writing Ability contract. Adapter executes; `.mary` package routes.
    public var adapterManifest: InstalledAdapterManifest {
        let adapterID = AdapterID("typer")
        func guarantee(
            _ kind: CapabilityConstraint.Kind,
            _ value: String
        ) -> CapabilityConstraint {
            CapabilityConstraint(kind: kind, value: value)
        }
        let guarantees: [CapabilityID: [CapabilityConstraint]] = [
            "text.write-at-surface": [
                guarantee(.requiresFrontmostApplication, "target-application"),
                guarantee(.sourceMustMatchTarget, "selection-source-when-replacing"),
            ],
            "text.resume-typing": [
                guarantee(.requiresFrontmostApplication, "original-target-application"),
                guarantee(.sourceMustMatchTarget, "paused-session-target"),
            ],
            // PIN: DictationRunner.typeSpan never activates — pinned caret must still own focus.
            "text.hold-dictation": [
                guarantee(.requiresFrontmostApplication, "target-application"),
            ],
            "document.passage.locate": [
                guarantee(.requiresStableDocumentIdentity, "when-provider-supports-documents"),
            ],
            "document.passage.replace": [
                guarantee(.requiresStableDocumentIdentity, "true"),
                guarantee(.sourceMustMatchTarget, "passage-document"),
            ],
            "document.passage.insert": [
                guarantee(.requiresStableDocumentIdentity, "true"),
                guarantee(.sourceMustMatchTarget, "passage-document"),
            ],
            "document.passage.delete": [
                guarantee(.requiresStableDocumentIdentity, "true"),
                guarantee(.sourceMustMatchTarget, "passage-document"),
            ],
            "document.passage.revert": [
                guarantee(.requiresStableDocumentIdentity, "true"),
            ],
        ]
        func operation(
            _ name: String,
            capabilities: [CapabilityID],
            input: ValueTypeID? = nil,
            perceptions: [PerceptionID] = [],
            target: String
        ) -> InstalledAdapterBinding {
            let enforced = Set(capabilities.flatMap { guarantees[$0] ?? [] })
            return InstalledAdapterBinding(
                adapterID: adapterID,
                operation: name,
                capabilities: capabilities,
                inputTypes: input.map { [$0] } ?? [],
                outputTypes: ["writing.operation-result"],
                observesPerceptions: perceptions,
                targetClasses: [target],
                enforcedConstraints: enforced.sorted {
                    ($0.kind.rawValue, $0.value) < ($1.kind.rawValue, $1.value)
                })
        }
        let contracts: [String: InstalledAdapterBinding] = [
            "type_at_cursor": operation(
                "type_at_cursor",
                capabilities: ["text.write-at-surface", "application.activate"],
                input: "writing.write-request",
                target: "editable-prose-surface"),
            "resume_typing": operation(
                "resume_typing",
                capabilities: ["text.resume-typing", "application.activate"],
                target: "editable-prose-surface"),
            "start_dictation": operation(
                "start_dictation",
                capabilities: ["text.hold-dictation", "application.activate"],
                target: "editable-prose-surface"),
            "stop_dictation": operation(
                "stop_dictation",
                capabilities: ["text.hold-dictation"],
                target: "editable-prose-surface"),
            "find_passage": operation(
                "find_passage",
                capabilities: ["document.passage.locate"],
                input: "writing.passage-request",
                perceptions: [.workspaceFocus],
                target: "document-workspace"),
            "replace_passage": operation(
                "replace_passage",
                capabilities: ["document.passage.replace"],
                input: "writing.passage-request",
                perceptions: [.workspaceFocus],
                target: "document-workspace"),
            "insert_passage": operation(
                "insert_passage",
                capabilities: ["document.passage.insert"],
                input: "writing.passage-request",
                perceptions: [.workspaceFocus],
                target: "document-workspace"),
            "delete_passage": operation(
                "delete_passage",
                capabilities: ["document.passage.delete"],
                input: "writing.passage-request",
                perceptions: [.workspaceFocus],
                target: "document-workspace"),
            "revert_last_edit": operation(
                "revert_last_edit",
                capabilities: ["document.passage.revert"],
                perceptions: [.workspaceFocus],
                target: "document-workspace"),
        ]
        return InstalledAdapterManifest(
            adapterID: adapterID,
            title: "Writing Surface",
            transport: .accessibility,
            claimCoverage: .complete,
            operations: skillBindings.map { binding in
                contracts[binding.name] ?? InstalledAdapterBinding(
                    adapterID: adapterID,
                    operation: binding.name)
            },
            supportedValueTypes: [
                "writing.write-request",
                "writing.passage-request",
                "writing.operation-result",
            ],
            grantedPermissions: [.accessibility])
    }

}
