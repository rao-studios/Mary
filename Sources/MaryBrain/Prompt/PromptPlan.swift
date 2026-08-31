//
//  PromptPlan.swift
//  MaryBrain
//
//  WHAT: Which sections, in which order.
//  IN:   PromptCatalog
//  OUT:  concatenated prompt string
//  PIN:  Renderer is pure concatenation; it supplies no separator of its own.
//
import Foundation

/// A defect found by `validate` — a plan that could not render correctly.
public struct PromptPlanDefect: Sendable, Equatable, CustomStringConvertible {
    public var plan: String
    public var detail: String
    public var description: String { "\(plan): \(detail)" }
}

public struct PromptPlan: Sendable {
    public var name: String
    /// THE ORDER IS THE DOCTRINE.
    public var order: [PromptSectionID]

    public init(name: String, order: [PromptSectionID]) {
        self.name = name
        self.order = order
    }

    // MARK: - Rendering

    public func render(
        _ inputs: PromptInputs, catalog: PromptCatalog = .standard
    ) -> PromptRender {
        var text = ""
        var spend: [PromptSpend] = []
        var claimedGroups: Set<PromptExclusiveGroup> = []

        for id in order {
            guard let section = catalog[id] else {
                spend.append(PromptSpend(
                    id: id, outcome: .omitted, chars: 0, rationale: "not in catalog"))
                continue
            }
            // Exclusivity resolves by PLAN ORDER — the first member to render claims the group, and later members are excluded rather than silently appended.
            if let group = section.exclusive, claimedGroups.contains(group) {
                spend.append(PromptSpend(
                    id: id, outcome: .excluded, chars: 0, rationale: section.rationale))
                continue
            }
            let piece = section.render(inputs)
            guard !piece.isEmpty else {
                spend.append(PromptSpend(
                    id: id, outcome: .gatedOut, chars: 0, rationale: section.rationale))
                continue
            }
            if let group = section.exclusive { claimedGroups.insert(group) }
            text += piece
            spend.append(PromptSpend(
                id: id, outcome: .rendered, chars: piece.count,
                rationale: section.rationale))
        }
        return PromptRender(text: text, spend: spend)
    }

    /// The rendered text alone — what every existing caller wants.
    public func text(
        _ inputs: PromptInputs, catalog: PromptCatalog = .standard
    ) -> String {
        render(inputs, catalog: catalog).text
    }

    // MARK: - Validation

    /// Pure structural checks — no rendering, no inputs. A plan that fails
    /// any of these is malformed however it is fed.
    public func validate(against catalog: PromptCatalog = .standard) -> [PromptPlanDefect] {
        var defects: [PromptPlanDefect] = []
        func fail(_ detail: String) {
            defects.append(PromptPlanDefect(plan: name, detail: detail))
        }

        var seen: Set<PromptSectionID> = []
        for id in order where !seen.insert(id).inserted {
            fail("section \(id.rawValue) appears more than once")
        }
        for id in order where catalog[id] == nil {
            fail("section \(id.rawValue) is not in the catalog")
        }
        // THE ORDERING DOCTRINE, checked. A terminal section is one nothing may follow
        for (index, id) in order.enumerated() {
            guard let section = catalog[id], section.ordering.terminal else { continue }
            let after = order[(index + 1)...]
            // Another terminal section after this one is fine only when the
            // two are mutually exclusive — at most one can render.
            let offenders = after.filter { later in
                guard let laterSection = catalog[later] else { return true }
                guard let group = section.exclusive,
                      laterSection.exclusive == group else { return true }
                return false
            }
            if !offenders.isEmpty {
                fail("\(id.rawValue) is terminal but \(offenders.map(\.rawValue).joined(separator: ", ")) follow it")
            }
        }
        return defects
    }
}

// MARK: - The plans

public extension PromptPlan {

    /// TODAY'S PROMPT, byte for byte. The order below is the exact sequence `MaryPrompts.system` appended in
    static let full = PromptPlan(
        name: "full",
        order: [
            .identity, .clock, .spokenRegister, .registerSwitch,
            .commandKinds, .stepwise, .confirmation,
            .rosterHeader, .rosterFragments, .eyesDoctrine, .compositionParadigm,
            .projects, .ambientNotes,
            .leadHeader, .leadSections,
            .coActiveSections,
            .heldFacts,
        ])

    /// THE VOICE LANE, byte for byte.
    /// PIN: The four personas are listed in the source's own `if / else if / else` order
    static let voice = PromptPlan(
        name: "voice",
        order: [
            .seerPreamble,
            .seerCompany, .seerHeading,
            .seerPersonaRead, .seerPersonaGrounded, .seerPersonaConverse,
            .seerPersonaInTurn,
            .seerCapability, .seerRetrieval,
            .seerSightPending,
            // BEFORE the live work, not after it. The turn loop used to append this to the finished string
            .seerRunningActions,
            .seerLiveWork,
        ])
}
