import Foundation

/// Reports machine-selected Ability contracts to the model without turning a
/// shared package into a prompt bundle. Only Mary-owned labels cross this
/// boundary. Package identifiers, versions, summaries, operating-policy prose,
/// cognitive descriptions, and workflow operation names stay on the
/// schema/runtime side; executable Skills are projected only through their
/// validated provider-call contracts.
public enum AbilityPromptProjection {
    public static func render(
        snapshot: AbilityRuntimeSnapshot,
        route: AmbientRoute?
    ) -> String {
        guard let route else { return "" }
        var active = route.gate.requestedAbilities
        switch route.intent {
        case .architect: active.insert(.architect)
        case .compose, .revise: active.insert(.writing)
        default: break
        }
        // THE LEAD'S OWN DISCIPLINE, asked of the roster. This compared the
        // lead against one compiled application, so an IDE the user taught
        // Mary never activated the coding ability no matter what it declared.
        if AmbientApplicationIndexProvider.current
            .registration(place: route.leadPlace)?.place.focus == .coding,
           route.intent != .converse {
            active.insert(.coding)
        }
        guard !active.isEmpty else { return "" }

        let records = snapshot.records.filter { active.contains($0.package.ability.id) }
            .sorted { $0.package.ability.id.rawValue < $1.package.ability.id.rawValue }
        guard !records.isEmpty else { return "" }

        var lines = [
            "\n[ABILITY REGISTRY \(snapshot.revision.uuidString)]",
            "The runtime selected these typed Ability contracts for this turn. Routing and local adapter safety are already enforced by the dispatcher.",
        ]
        for record in records {
            let ability = record.package.ability
            let readyCount = snapshot.skills.filter {
                $0.ability.id == ability.id && $0.availability.readiness == .ready
            }.count
            lines.append(
                "ABILITY \(contractLabel(for: record)) — \(readyCount) executable Skill contract(s)")
            // CLOSED CAUTION CATEGORIES ONLY. `operatingPolicy.guardrails`
            // stays permanently free-text and never reaches this projection
            // — a named regression test in AbilityPromptProjectionSecurityTests
            // guards that boundary. `guardrailCategories` is the one
            // ability-level caution signal this projection reads, and every
            // line it emits below is one of the fixed sentences from
            // `guardrailSentence(for:)`; package data selects only which
            // closed cases apply, never any wording.
            for category in ability.operatingPolicy.guardrailCategories {
                lines.append("  CAUTION: \(guardrailSentence(for: category))")
            }
        }
        lines.append("[END ABILITY REGISTRY]")
        return lines.joined(separator: "\n")
    }

    /// The fixed, Mary-owned sentence for one closed `GuardrailCategory`.
    /// `Switch` is exhaustive over the enum, so a new case fails to compile
    /// here until it is given real wording — there is no default branch that
    /// could accidentally let package data supply the text instead.
    static func guardrailSentence(for category: GuardrailCategory) -> String {
        switch category {
        case .domainMismatch:
            return "Domain caution: do not apply this outside the surface kind it was built for (for example, prose vs. code)."
        case .unscopedTarget:
            return "Scope caution: act only on the target the user explicitly named or focused, never an inferred neighbor."
        case .staleState:
            return "Freshness caution: read live state before acting or reporting; never answer from a remembered value."
        case .noFocusSteal:
            return "Focus caution: never bring the target forward or steal focus merely to observe or command it."
        case .nativeCommandOnly:
            return "Command caution: issue this through the target application's own command, never synthesized input standing in for it."
        case .irreversibleAction:
            return "Irreversible caution: this can destroy or replace existing content; confirm the exact, fresh target before acting."
        }
    }

    /// Do not echo an IMPORTED identifier into high-priority model context.
    ///
    /// This used to be a hand-maintained switch, which meant every new
    /// `.mary` — including one Mary ships herself — read as `CUSTOM` to the
    /// model until somebody remembered to add a case here. A package should be
    /// droppable into the repository and be named correctly without editing
    /// Swift, so the label is now DERIVED, gated on provenance rather than on a
    /// list: Mary's own bytes get their name, imported bytes stay opaque. See
    /// `AbilityPackageTrustStatus.permitsDerivedContractLabel` for why that is
    /// the honest line to draw.
    static func contractLabel(for record: AbilityPackageRecord) -> String {
        guard record.trustStatus.permitsDerivedContractLabel else { return "CUSTOM" }
        return derivedLabel(for: record.package.ability.id)
    }

    /// A validated identifier shaped into a registry label: `window-management`
    /// reads as `WINDOW MANAGEMENT`.
    ///
    /// Sanitised even though the schema validator already bounds the id, and
    /// even though only Mary's own bytes reach here. It costs four lines and
    /// it makes the function TOTAL — there is no id, however odd, that turns
    /// this into a sentence. Anything left empty falls back to `CUSTOM` rather
    /// than emitting a blank label.
    static func derivedLabel(for abilityID: AbilityID) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ")
        let spaced = abilityID.rawValue
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .uppercased()
        let cleaned = String(spaced.filter { allowed.contains($0) })
            .split(separator: " ")
            .joined(separator: " ")
        guard !cleaned.isEmpty else { return "CUSTOM" }
        return String(cleaned.prefix(48))
    }
}
