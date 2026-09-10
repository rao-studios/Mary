//
//  ThreadContextStore+RoutingHabits.swift
//  MaryRuntime
//
//  WHAT: Routing habits as PERSONAL MEMORY — deposited to and recalled from
//        the user's own thread, not a cache file on one machine.
//  IN:   RoutingHabitMemory (MaryBrain installs the seam; this fills it)
//  OUT:  ThreadDirectClient deposit / search
//  PIN:  THE LABEL RIDES IN THE DOCUMENT ID. `ThreadPartitionResult` returns
//        documentID, text and score — NOT the `metadata` an index item accepts —
//        so the Skill and intent a habit teaches must be readable from the id
//        alone, and eviction can address the row exactly.
//
import MaryBrain
import MaryFoundation
import MaryThread
import Foundation

extension ThreadContextStore {

    /// `mary-routing-<intent>|<skillID>|<epochSeconds>`
    ///
    /// THE PREFIX IS THE HOUSE CONVENTION and it is load-bearing:
    /// `ThreadAddressClassifier` reads families from prefixes alone, so an
    /// address that does not start `mary-<family>-` shows up in the Threads
    /// pane as "Unrecognized" no matter what it holds.
    /// The payload is pipe-separated because Skill ids are dotted and
    /// hyphenated; a pipe appears in neither, so parsing back is unambiguous.
    enum RoutingHabitAddress {
        static let prefix = "mary-routing-"

        static func documentID(for habit: RoutingHabit) -> String {
            prefix + [
                habit.intent,
                habit.skillID,
                String(Int(habit.storedAt.timeIntervalSince1970)),
            ].joined(separator: "|")
        }

        /// The habit a recalled document teaches, or nil when the id is not
        /// one of ours (a thread holds more than routing memory).
        static func habit(documentID: String, text: String) -> RoutingHabit? {
            guard documentID.hasPrefix(prefix) else { return nil }
            let parts = documentID.dropFirst(prefix.count)
                .split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 3, let seconds = TimeInterval(parts[2])
            else { return nil }
            return RoutingHabit(
                query: text,
                skillID: String(parts[1]),
                intent: String(parts[0]),
                // Only successes are ever taught — see the dispatch chokepoint.
                ok: true,
                storedAt: Date(timeIntervalSince1970: seconds))
        }
    }

    /// The group routing memory lives in, per owner — `mary-routing-<owner>`,
    /// the same shape as `mary-style-<owner>` and the interaction group, so the
    /// Threads pane files it under the Personal lane rather than Unrecognized.
    static func routingHabitGroup(ownerID: String) -> (id: String, label: String) {
        ("mary-routing-\(ownerID)", "Mary · how you ask")
    }

    package func rememberRoutingHabit(_ habit: RoutingHabit) async {
        guard let owner = await session.userID else { return }
        let group = Self.routingHabitGroup(ownerID: owner)
        let item = DepositItem(
            documentID: RoutingHabitAddress.documentID(for: habit),
            // THE BARE UTTERANCE, and nothing else: this text is what a later
            // turn is compared against, so anything added to it dilutes the
            // very comparison the habit exists to make.
            texts: [habit.query],
            name: "Routing · \(habit.skillID)",
            mediaType: "text/plain")
        do {
            _ = try await client.deposit(
                [item], ownerID: owner,
                groupID: group.id, groupLabel: group.label,
                scope: ThreadLane.personal.rawValue)
        } catch {
            // A habit that cannot be stored is a habit not learned, never a
            // failed turn — the dispatch already succeeded.
            let line = "routing habit deposit failed — \(error.localizedDescription)"
            BehavioralAssembler.behavioralLog.info("\(line, privacy: .public)")
        }
    }

    package func recallRoutingHabits(
        near utterance: String, limit: Int
    ) async -> [RoutingHabit] {
        guard let owner = await session.userID,
              !utterance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return [] }
        let group = Self.routingHabitGroup(ownerID: owner)
        do {
            let hits = try await client.search(
                query: utterance,
                ownerID: owner,
                scope: ThreadLane.personal.rawValue,
                topK: limit,
                groupIDs: [group.id],
                // A TURN IS WAITING. The default is thirty seconds, which is a
                // reasonable budget for a library page and an absurd one here.
                timeout: .seconds(2))
            return hits.compactMap {
                RoutingHabitAddress.habit(documentID: $0.documentID, text: $0.text)
            }
        } catch {
            // Thread down, mid-restart, or slow: this turn routes on its
            // authored corpus alone, exactly as a fresh install does.
            return []
        }
    }
}

/// The seam MaryBrain reads, filled by the runtime's thread.
///
/// A thin forwarder rather than a stored client: the context store is an actor
/// whose `client` is re-pointed whenever the user changes the Thread port in
/// Settings, and routing memory must follow that without being re-installed.
struct ThreadRoutingHabitMemory: RoutingHabitMemory {
    func remember(_ habit: RoutingHabit) async {
        await MaryRuntime.threadContext.rememberRoutingHabit(habit)
    }

    func recall(near utterance: String, limit: Int) async -> [RoutingHabit] {
        await MaryRuntime.threadContext.recallRoutingHabits(near: utterance, limit: limit)
    }
}

