//
//  ContextEntityComposer.swift
//  MaryRuntime
//
//  WHAT: Explicit Totem graph payload for an archived Ability run.
//  OUT:  TotemEntityIn / TotemRelationIn on the deposit
//

import MaryBrain
import MaryTotem
import Foundation

package enum ContextEntityComposer {

    package struct Composition: Equatable {
        package var entities: [TotemEntityIn] = []
        package var relationships: [TotemRelationIn] = []

        package init(entities: [TotemEntityIn] = [], relationships: [TotemRelationIn] = []) {
            self.entities = entities
            self.relationships = relationships
        }
    }

    /// Mary-specific graph kinds registered with Totem's managed policy.
    package static let customKinds = [
        "file", "document", "project", "app",
        "ability-package", "ability", "skill",
    ]

    package static func compose(
        reference: AbilitySkillReference,
        argumentsJSON: String,
        userText: String,
        userName: String,
        projectRoot: String?,
        activeFilePath: String?,
        app: String? = nil,
        document: String? = nil
    ) -> Composition {
        var composition = Composition()
        let user = userName.trimmingCharacters(in: .whitespaces)
        let packageName = "\(reference.packageID.rawValue)@\(reference.packageVersion.rawValue)"
        let abilityName = reference.abilityID.rawValue
        let skillName = reference.skillID.rawValue
        let application = app?.trimmingCharacters(in: .whitespaces)
        let filePath = activeFilePath
        let proseDocument: String? = filePath == nil
            ? document?.trimmingCharacters(in: .whitespaces)
            : nil

        composition.entities.append(TotemEntityIn(name: packageName, kind: "ability-package"))
        composition.entities.append(TotemEntityIn(name: abilityName, kind: "ability"))
        composition.entities.append(TotemEntityIn(name: skillName, kind: "skill"))
        composition.relationships.append(
            TotemRelationIn(subject: packageName, predicate: "exports", object: abilityName))
        composition.relationships.append(
            TotemRelationIn(subject: abilityName, predicate: "contains", object: skillName))
        if !user.isEmpty {
            composition.entities.append(TotemEntityIn(name: user, kind: "person"))
            composition.relationships.append(
                TotemRelationIn(subject: user, predicate: "invoked", object: skillName))
        }

        if let application, !application.isEmpty {
            let appName = displayName(application)
            composition.entities.append(TotemEntityIn(name: appName, kind: "app"))
            composition.relationships.append(
                TotemRelationIn(subject: skillName, predicate: "runs through", object: appName))
        }

        // Prose work, given graph identity. Every endpoint below ships as an
        // entity in this same item — the Totem rule the header states.
        if let proseDocument, !proseDocument.isEmpty {
            composition.entities.append(TotemEntityIn(name: proseDocument, kind: "document"))
            composition.relationships.append(
                TotemRelationIn(subject: skillName, predicate: "used on", object: proseDocument))
            if !user.isEmpty {
                composition.relationships.append(
                    TotemRelationIn(subject: user, predicate: "works on", object: proseDocument))
            }
            if let projectRoot, !projectRoot.isEmpty {
                let project = (projectRoot as NSString).lastPathComponent
                composition.entities.append(TotemEntityIn(name: project, kind: "project"))
                composition.relationships.append(
                    TotemRelationIn(subject: proseDocument, predicate: "part of", object: project))
                if !user.isEmpty {
                    composition.relationships.append(
                        TotemRelationIn(subject: user, predicate: "works on", object: project))
                }
            }
            return composition
        }

        if let projectRoot, !projectRoot.isEmpty {
            let project = (projectRoot as NSString).lastPathComponent
            composition.entities.append(TotemEntityIn(name: project, kind: "project"))
            if !user.isEmpty {
                composition.relationships.append(
                    TotemRelationIn(subject: user, predicate: "works on", object: project))
            }
            if let filePath, !filePath.isEmpty {
                let file = relativePath(filePath, projectRoot: projectRoot)
                composition.entities.append(TotemEntityIn(name: file, kind: "file"))
                composition.relationships.append(
                    TotemRelationIn(subject: file, predicate: "part of", object: project))
                composition.relationships.append(
                    TotemRelationIn(subject: skillName, predicate: "used on", object: file))
            }
        }

        return composition
    }

    /// Project-relative path when the file lives under the root (the stable
    /// canonical name); absolute otherwise.
    package static func relativePath(_ path: String, projectRoot: String) -> String {
        let root = projectRoot.hasSuffix("/") ? projectRoot : projectRoot + "/"
        guard path.hasPrefix(root) else { return path }
        return String(path.dropFirst(root.count))
    }

    private static func displayName(_ application: String) -> String {
        application
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
}
