//
//  TotemContextStore+ApplicationHabits.swift
//  MaryRuntime
//
//  WHAT: Which application this person reaches for, as PERSONAL MEMORY.
//  IN:   ApplicationHabitMemory (MaryBrain installs the seam; this fills it)
//  OUT:  TotemDirectClient deposit / documents
//  PIN:  ONE REPLACED DOCUMENT PER DISCIPLINE, not one per act. A habit is
//        asked for by name ("who leads multimedia") and never by resemblance,
//        so this is the style-profile shape rather than the habit shape:
//        `documents(ids:)` restores it in one call, and a forget is an empty
//        ledger deposited over the old one rather than a hunt for rows.
//
import Foundation
import MaryBrain
import MaryFoundation
import MaryTotem

extension TotemContextStore {

    /// The group habits live in, per owner — the same shape as
    /// `mary-style-<owner>`, so the Totems pane files it under Personal.
    static func applicationHabitGroup(ownerID: String) -> (id: String, label: String) {
        let group = TotemMemoryTopology.applicationHabitGroup(ownerID: ownerID)
        return (group.id, group.label)
    }

    package func rememberApplicationHabits(
        _ habits: [ApplicationHabit], discipline: AbilityID
    ) async {
        guard let owner = await session.userID else { return }
        // An EMPTY ledger is deposited, not skipped — that is how a forget
        // becomes durable (see `depositStyleProfile`, same reasoning).
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(habits),
              let content = String(data: data, encoding: .utf8)
        else { return }
        let group = Self.applicationHabitGroup(ownerID: owner)
        let item = DepositItem(
            documentID: TotemMemoryTopology.applicationHabitLedgerDocumentID(
                discipline: discipline.rawValue, ownerID: owner),
            texts: [content],
            tags: ["mary", "application-habit", discipline.rawValue],
            name: "Habits · \(discipline.rawValue)",
            mediaType: "application/json")
        do {
            _ = try await client.deposit(
                [item], ownerID: owner,
                groupID: group.id, groupLabel: group.label,
                scope: TotemLane.personal.rawValue)
        } catch {
            // A habit that cannot be stored is a habit not learned, never a
            // failed turn — the dispatch already succeeded.
            let line = "application habit deposit failed — \(error.localizedDescription)"
            BehavioralAssembler.behavioralLog.info("\(line, privacy: .public)")
        }
    }

    package func recallApplicationHabits(
        discipline: AbilityID
    ) async -> [ApplicationHabit] {
        guard let owner = await session.userID else { return [] }
        let id = TotemMemoryTopology.applicationHabitLedgerDocumentID(
            discipline: discipline.rawValue, ownerID: owner)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let documents = try? await client.documents(ids: [id], ownerID: owner),
              let content = documents.first?.content,
              let habits = try? decoder.decode(
                  [ApplicationHabit].self, from: Data(content.utf8))
        else {
            // Totem down, mid-restart, or nothing stored yet: this launch
            // ranks on declared preference alone, exactly as a fresh install.
            return []
        }
        return habits
    }
}

/// The seam MaryBrain reads, filled by the runtime's totem. A thin forwarder
/// rather than a stored client, for the reason `TotemRoutingHabitMemory`
/// gives: the context store's client is re-pointed when the Totem port
/// changes in Settings, and habits must follow that without reinstalling.
struct TotemApplicationHabitMemory: ApplicationHabitMemory {
    func remember(_ habits: [ApplicationHabit], discipline: AbilityID) async {
        await MaryRuntime.totemContext.rememberApplicationHabits(
            habits, discipline: discipline)
    }

    func recall(discipline: AbilityID) async -> [ApplicationHabit] {
        await MaryRuntime.totemContext.recallApplicationHabits(discipline: discipline)
    }
}
