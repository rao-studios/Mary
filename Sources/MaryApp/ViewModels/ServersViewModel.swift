//
//  ServersViewModel.swift
//  Mary
//
//  Bridges LocalStackManager's actor snapshots to SwiftUI: a live status
//  stream while the Servers sheet is open, auth state, and build output
//  tails. Actions forward to the shared manager/session.
//

import MaryBrain
import MaryTotem
import Foundation
import SwiftUI
import MaryRuntime

@MainActor
final class ServersViewModel: ObservableObject {

    @Published var snapshots: [ServerStatusSnapshot] = []
    @Published var isAuthenticated = false
    @Published var ownerID: String?
    @Published var authNotice: String?
    @Published var buildTails: [ServerSpec.Kind: [String]] = [:]
    @Published var buildingKinds: Set<ServerSpec.Kind> = []
    @Published var graphStats: GraphStats?
    @Published var isClearing = false
    @Published var clearNotice: String?

    private var streamTask: Task<Void, Never>?
    private var authTask: Task<Void, Never>?

    func start() {
        guard streamTask == nil else { return }
        streamTask = Task { [weak self] in
            let stream = await MaryRuntime.localStack.statusStream()
            for await snapshots in stream {
                guard let self, !Task.isCancelled else { return }
                self.snapshots = snapshots
            }
        }
        authTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.isAuthenticated = await MaryRuntime.seerSession.isAuthenticated
                self.ownerID = await MaryRuntime.seerSession.userID
                await self.refreshGraphStats()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private func refreshGraphStats() async {
        guard let owner = ownerID,
              snapshots.first(where: { $0.kind == .totem })?.status == .healthy else {
            return
        }
        let reader = MaryRuntime.makeTotemReader()
        graphStats = try? await reader.graphStats(ownerID: owner)
    }

    /// Wipes Mary's deposited context — BOTH pools: the legacy owner-wide
    /// `mary-context-<owner>` group and the per-document/project
    /// `mary-scope-…` groups deposits are filed into when something is in
    /// view. Missing the second set would leave "Clear Mary's context"
    /// quietly partial, which is the failure mode that button exists to
    /// prevent. Saved memories and other groups stay intact.
    func clearMaryContext() {
        clear(label: "Mary's context") { reader, owner in
            let legacy = try await reader.clearGroups(
                prefix: "mary-context-\(owner)", ownerID: owner)
            let scoped = try await reader.clearGroups(
                prefix: "mary-scope-", ownerID: owner)
            let application = try await reader.clearGroups(
                prefix: "mary-application-", ownerID: owner)
            return legacy + scoped + application
        }
    }

    /// Wipes EVERY document owned by the signed-in account on the node,
    /// including saved memories. Node identity / DB file are preserved.
    func clearEverything() {
        clear(label: "everything") { reader, owner in
            try await reader.clearOwner(ownerID: owner)
        }
    }

    /// Shared runner for the two Clear buttons: guards (signed in + Totem
    /// healthy), runs the removal off the main actor, then refreshes the graph
    /// line and posts a spoken-plain notice. Reuses the same reader + guards as
    /// `refreshGraphStats()`.
    private func clear(
        label: String,
        _ operation: @escaping @Sendable (TotemDirectClient, String) async throws -> Int
    ) {
        guard !isClearing else { return }
        guard let owner = ownerID,
              snapshots.first(where: { $0.kind == .totem })?.status == .healthy else {
            clearNotice = "Sign in and start Totem first."
            return
        }
        isClearing = true
        clearNotice = nil
        Task { [weak self] in
            let reader = MaryRuntime.makeTotemReader()
            let notice: String
            do {
                let removed = try await operation(reader, owner)
                await MaryRuntime.resetAmbientMemory()
                notice = "Cleared \(label) — \(removed) \(removed == 1 ? "item" : "items") removed."
            } catch {
                notice = "Couldn't clear \(label): \(error.localizedDescription)"
            }
            guard let self else { return }
            self.isClearing = false
            self.clearNotice = notice
            await self.refreshGraphStats()
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        authTask?.cancel()
        authTask = nil
    }

    func startServer(_ kind: ServerSpec.Kind) {
        Task { _ = await MaryRuntime.localStack.start(kind) }
    }

    func stopServer(_ kind: ServerSpec.Kind) {
        Task { await MaryRuntime.localStack.stop(kind) }
    }

    func restartServer(_ kind: ServerSpec.Kind) {
        Task { _ = await MaryRuntime.localStack.restart(kind) }
    }

    func build(_ kind: ServerSpec.Kind) {
        guard !buildingKinds.contains(kind) else { return }
        buildingKinds.insert(kind)
        buildTails[kind] = []
        Task { [weak self] in
            let lines = await MaryRuntime.localStack.build(kind)
            for await line in lines {
                guard let self else { return }
                var tail = self.buildTails[kind] ?? []
                tail.append(line)
                if tail.count > 6 { tail.removeFirst(tail.count - 6) }
                self.buildTails[kind] = tail
            }
            self?.buildingKinds.remove(kind)
        }
    }

    func signIn(email: String, password: String, port: Int) {
        Task { [weak self] in
            let error = await MaryRuntime.applySeerAccount(
                email: email, password: password, seerPort: port)
            guard let self else { return }
            self.authNotice = error
            self.isAuthenticated = await MaryRuntime.seerSession.isAuthenticated
            self.ownerID = await MaryRuntime.seerSession.userID
            if error == nil {
                await MaryRuntime.connectSeerToBrain(enabled: true)
                // Seer means Seer: a session that booted unauthenticated
                // parked speech elsewhere — a successful sign-in is the
                // moment the configured backend can finally hold.
                _ = await MaryRuntime.reapplyTTSBackend()
            }
        }
    }
}
