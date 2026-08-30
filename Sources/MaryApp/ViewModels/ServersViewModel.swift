//
//  ServersViewModel.swift
//  Mary
//
//  WHAT: LocalStackManager snapshots → SwiftUI (status, auth, build tails).
//  OUT:  ServersSheet. Actions forward to shared manager/session.
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

    /// Wipes Mary's deposited context — project scopes, Ability codec,
    /// Personal interactions, and style profiles. Node identity stays.
    func clearMaryContext() {
        clear(label: "Mary's context") { reader, owner in
            let scoped = try await reader.clearGroups(
                prefix: "mary-scope-", ownerID: owner)
            let ability = try await reader.clearGroups(
                prefix: "mary-ability-", ownerID: owner)
            let interactions = try await reader.clearGroups(
                prefix: "mary-behavior-", ownerID: owner)
            let style = try await reader.clearGroups(
                prefix: "mary-style-", ownerID: owner)
            return scoped + ability + interactions + style
        }
    }

    /// Wipes EVERY document owned by the signed-in account on the node,
    /// including saved memories. Node identity / DB file are preserved.
    func clearEverything() {
        clear(label: "everything") { reader, owner in
            try await reader.clearOwner(ownerID: owner)
        }
    }

    /// Clear-button runner: guard, remove off-main, refresh; same guards as refreshGraphStats.
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
                // The Brain card still decides where the words go; signing
                // in only makes the server available to be chosen.
                await MaryRuntime.connectSeerToBrain(
                    chat: MaryRuntime.seerCarriesTurns(seerEnabled: true),
                    archiving: true,
                    stackEnabled: true)
                // Seer means Seer: a session that booted unauthenticated
                // parked speech elsewhere — a successful sign-in is the
                // moment the configured backend can finally hold.
                _ = await MaryRuntime.reapplyTTSBackend()
            }
        }
    }
}
