//
//  TotemContextStore+RoutingExemplars.swift
//  MaryRuntime
//
//  WHAT: Routing lessons as PERSONAL MEMORY — deposited to and recalled from
//        the user's own totem, not a cache file on one machine.
//  IN:   RoutingExemplarMemory (MaryBrain installs the seam; this fills it)
//  OUT:  TotemDirectClient deposit / search
//  PIN:  THE LABEL RIDES IN THE DOCUMENT ID. `TotemPartitionResult` returns
//        documentID, text and score — NOT the `metadata` an index item accepts —
//        so the Skill and intent a lesson teaches must be readable from the id
//        alone, and eviction can address the row exactly.
//
import MaryBrain
import MaryFoundation
import MaryTotem
import Foundation

extension TotemContextStore {

    /// `mary.exemplar|<intent>|<skillID>|<epochSeconds>`
    ///
    /// Pipe-separated because Skill ids are dotted and group ids are slashed;
    /// a pipe appears in neither, so parsing back is unambiguous.
    enum ExemplarAddress {
        static let prefix = "mary.exemplar"

        static func documentID(for exemplar: RoutingExemplar) -> String {
            [
                prefix,
                exemplar.intent,
                exemplar.skillID,
                String(Int(exemplar.storedAt.timeIntervalSince1970)),
            ].joined(separator: "|")
        }

        /// The lesson a recalled document teaches, or nil when the id is not
        /// one of ours (a totem holds more than routing memory).
        static func exemplar(documentID: String, text: String) -> RoutingExemplar? {
            let parts = documentID.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 4, parts[0] == prefix,
                  let seconds = TimeInterval(parts[3])
            else { return nil }
            return RoutingExemplar(
                query: text,
                skillID: String(parts[2]),
                intent: String(parts[1]),
                // Only successes are ever taught — see the dispatch chokepoint.
                ok: true,
                storedAt: Date(timeIntervalSince1970: seconds))
        }
    }

    /// The group routing memory lives in, per owner.
    static func exemplarGroup(ownerID: String) -> (id: String, label: String) {
        ("\(ownerID)/mary-routing", "Mary · how you ask")
    }

    package func rememberRoutingExemplar(_ exemplar: RoutingExemplar) async {
        guard let owner = await session.userID else { return }
        let group = Self.exemplarGroup(ownerID: owner)
        let item = DepositItem(
            documentID: ExemplarAddress.documentID(for: exemplar),
            // THE BARE UTTERANCE, and nothing else: this text is what a later
            // turn is compared against, so anything added to it dilutes the
            // very comparison the lesson exists to make.
            texts: [exemplar.query],
            name: "Routing · \(exemplar.skillID)",
            mediaType: "text/plain")
        do {
            _ = try await client.deposit(
                [item], ownerID: owner,
                groupID: group.id, groupLabel: group.label,
                scope: TotemLane.personal.rawValue)
        } catch {
            // A lesson that cannot be stored is a lesson not learned, never a
            // failed turn — the dispatch already succeeded.
            let line = "routing exemplar deposit failed — \(error.localizedDescription)"
            BehavioralAssembler.behavioralLog.info("\(line, privacy: .public)")
        }
    }

    package func recallRoutingExemplars(
        near utterance: String, limit: Int
    ) async -> [RoutingExemplar] {
        guard let owner = await session.userID,
              !utterance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return [] }
        let group = Self.exemplarGroup(ownerID: owner)
        do {
            let hits = try await client.search(
                query: utterance,
                ownerID: owner,
                scope: TotemLane.personal.rawValue,
                topK: limit,
                groupIDs: [group.id],
                // A TURN IS WAITING. The default is thirty seconds, which is a
                // reasonable budget for a library page and an absurd one here.
                timeout: .seconds(2))
            return hits.compactMap {
                ExemplarAddress.exemplar(documentID: $0.documentID, text: $0.text)
            }
        } catch {
            // Totem down, mid-restart, or slow: this turn routes on its
            // authored corpus alone, exactly as a fresh install does.
            return []
        }
    }
}

/// The seam MaryBrain reads, filled by the runtime's totem.
///
/// A thin forwarder rather than a stored client: the context store is an actor
/// whose `client` is re-pointed whenever the user changes the Totem port in
/// Settings, and routing memory must follow that without being re-installed.
struct TotemRoutingExemplarMemory: RoutingExemplarMemory {
    func remember(_ exemplar: RoutingExemplar) async {
        await MaryRuntime.totemContext.rememberRoutingExemplar(exemplar)
    }

    func recall(near utterance: String, limit: Int) async -> [RoutingExemplar] {
        await MaryRuntime.totemContext.recallRoutingExemplars(near: utterance, limit: limit)
    }
}

extension TotemContextStore {

    /// The file previous builds kept routing lessons in.
    static var legacyExemplarFile: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return support
            .appendingPathComponent("Mary", isDirectory: true)
            .appendingPathComponent("routing-exemplars.json")
    }

    /// ONE-SHOT: carry the local file's lessons into personal memory, then
    /// remove it.
    ///
    /// MIGRATED, NOT DELETED. The legacy behaviour directory could simply be
    /// removed because Totem already held everything in it; this file is the
    /// only copy of how a particular person has been asking for things, and
    /// dropping it would silently reset their routing to a fresh install.
    ///
    /// The file survives a failed migration on purpose — if the totem is
    /// unreachable the next launch tries again, and nothing is lost in the
    /// meantime.
    package func migrateLegacyRoutingExemplars() async {
        let file = Self.legacyExemplarFile
        guard let data = try? Data(contentsOf: file),
              let rows = try? JSONDecoder().decode([RoutingExemplar].self, from: data)
        else { return }
        guard await session.userID != nil else { return }

        let cutoff = Date().addingTimeInterval(-RoutingExemplarStore.horizon)
        let live = rows.filter { $0.storedAt >= cutoff && $0.ok }
        for row in live {
            await rememberRoutingExemplar(row)
        }
        // Only once every lesson has been offered to memory.
        try? FileManager.default.removeItem(at: file)
        let line = "migrated \(live.count) routing exemplar(s) into personal memory"
        BehavioralAssembler.behavioralLog.info("\(line, privacy: .public)")
    }
}
