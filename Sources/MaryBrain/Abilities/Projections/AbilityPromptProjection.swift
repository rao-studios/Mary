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
        }
        lines.append("[END ABILITY REGISTRY]")
        return lines.joined(separator: "\n")
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
