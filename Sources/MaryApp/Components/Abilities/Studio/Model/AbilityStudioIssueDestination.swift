//
//  AbilityStudioIssueDestination.swift
//  Mary
//
//  WHAT: Which pane owns a validation issue.
//  IN:   Advanced ▸ Issues.
//  OUT:  AbilityStudioView focus ring.
//  PIN:  Replaces the old editor's stage(for:) path switch. Same idea, three
//        panes instead of five stages.
//

import MaryBrain
import Foundation

/// The surfaces an issue can send you to.
enum AbilityStudioPane: String, Hashable {
    case recipe
    case tune
    case skills
    /// Contracts, projections and fixtures live in the drawer itself.
    case advanced

    var title: String {
        switch self {
        case .recipe: return "Recipe"
        case .tune: return "Tune"
        case .skills: return "Skills"
        case .advanced: return "Advanced"
        }
    }
}

enum AbilityStudioIssueDestination {

    /// Schema paths are dotted and indexed (`apple-music.skills[0].execution.steps[1]`),
    /// so matching is by substring rather than by parsing.
    static func pane(for issue: SchemaIssue) -> AbilityStudioPane {
        let path = issue.path

        // A step is a recipe row before it is a skill.
        if path.contains("execution.steps") { return .recipe }
        if path.contains("plugin.operations") || path.contains("plugin.adapter") {
            return .recipe
        }
        if path.contains("triggers")
            || path.contains("operatingPolicy")
            || path.contains("routing")
            || path.contains("ability.paradigm")
            || path.contains("plugin.application")
            || path.contains("applications") {
            return .tune
        }
        if path.contains("skills") { return .skills }
        if path.contains("capabilities")
            || path.contains("valueTypes")
            || path.contains("interactions")
            || path.contains("perceptions")
            || path.contains("threadProjections")
            || path.contains("dependencies")
            || path.contains("fixtures")
            || path.contains("corpus") {
            return .advanced
        }
        // Package identity and anything unrecognised: the raw schema is the
        // one place every field is reachable.
        return .advanced
    }

    /// The last readable segment of a path, for a row's caption.
    static func where_(_ issue: SchemaIssue) -> String {
        let parts = issue.path.split(separator: ".")
        return parts.suffix(2).joined(separator: ".")
    }
}
