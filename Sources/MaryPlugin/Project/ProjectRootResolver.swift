//
//  ProjectRootResolver.swift
//  MaryPlugin
//
//  WHAT: The live project root from whichever package is focused.
//  IN:   AbilityExecutionContext / ProjectCorpusSupport
//  OUT:  ProjectGitAdapter / ProjectBuildAdapter / ProjectQuirksAdapter /
//        CodingAgentAdapter
//  PIN:  Never an application name.
//

import Foundation
import MaryFoundation

enum ProjectRootResolver {

    struct Focus: Sendable {
        var root: String
        var name: String
        var registration: CorpusRegistration?
    }

    struct Refusal: Error {
        var spoken: String
    }

    static func live(
        named: String?,
        context: AbilityExecutionContext
    ) -> Result<Focus, Refusal> {
        if let named, !named.isEmpty {
            let wanted = named.lowercased()
            if let pair = context.projects.first(where: {
                $0.key.lowercased() == wanted
            }) {
                return .success(Focus(root: pair.value, name: pair.key, registration: nil))
            }
            switch ProjectCorpusSupport.resolve(named) {
            case .success(let corpus):
                return .success(Focus(
                    root: corpus.projectRoot.path, name: corpus.name,
                    registration: corpus.registration))
            case .failure(let refusal):
                return .failure(Refusal(spoken: refusal.spoken))
            }
        }
        switch ProjectCorpusSupport.resolve(nil) {
        case .success(let corpus):
            return .success(Focus(
                root: corpus.projectRoot.path, name: corpus.name,
                registration: corpus.registration))
        case .failure:
            break
        }
        if let root = context.codingProjectRoot, !root.isEmpty {
            return .success(Focus(
                root: root,
                name: URL(fileURLWithPath: root).lastPathComponent,
                registration: nil))
        }
        if let only = context.projects.first, context.projects.count == 1 {
            return .success(Focus(root: only.value, name: only.key, registration: nil))
        }
        return .failure(Refusal(spoken: "I don't know which project you're in — open a file, or name one."))
    }
}
