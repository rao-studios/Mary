//
//  ServersSheet.swift
//  Mary
//
//  The local stack's control room: Seer, Totem, and Fleet status with start/stop/
//  restart/build, the account that authenticates the APIs, and the stack
//  configuration (checkouts, ports, totem identity). Servers auto-launch at
//  boot and die with the app; this sheet is for watching and overriding.
//

import MaryBrain
import Granite
import SwiftUI
import MaryRuntime

struct ServersSheet: View {
    @Relay var config: ConfigService
    @Environment(\.dismiss) private var dismiss

    @StateObject private var viewModel = ServersViewModel()

    // Staged edits — committed by "Apply & Restart" so keystrokes don't
    // thrash the stack.
    @State private var seerPath = ""
    @State private var totemPath = ""
    @State private var seerPortText = ""
    @State private var totemPortText = ""
    @State private var email = ""
    @State private var password = ""
    @State private var confirmRegenerate = false
    @State private var confirmClearContext = false
    @State private var confirmClearAll = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: .layer4) {
                header

                enableCard

                ForEach(viewModel.snapshots) { snapshot in
                    serverCard(snapshot)
                }

                accountCard
                stackConfigCard
            }
            .padding(.layer4)
        }
        .background(Paper.page)
        .frame(width: 480, height: 620)
        .onAppear {
            viewModel.start()
            seerPath = config.state.seerCheckoutPath
            totemPath = config.state.totemCheckoutPath
            seerPortText = String(config.state.seerPort)
            totemPortText = String(config.state.totemPort)
            email = config.state.seerEmail
            password = config.state.seerPassword
        }
        .onDisappear { viewModel.stop() }
    }

    private var header: some View {
        HStack {
            MaryMark(size: 18)
            Text("Servers")
                .font(.marySerif(18, weight: .light, italic: true))
                .foregroundStyle(Color.maryInk)
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.mary)
        }
    }

    // MARK: - Enable / auto-start

    private var enableCard: some View {
        MaryCard {
            VStack(alignment: .leading, spacing: .layer3) {
                SectionLabel("Seer")
                Toggle(isOn: seerEnabledBinding) {
                    Text("Chat through Seer")
                        .font(.marySans(12, weight: .medium))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                Text("On: the local Seer stack is available for Voice (Lane A) and Skills (Lane B), each chosen in Settings. Off: both stay on-device.")
                    .font(.marySans(11))
                    .foregroundStyle(Color.maryInk.opacity(0.6))
                Toggle(isOn: autoStartBinding) {
                    Text("Start servers with Mary")
                        .font(.marySans(12, weight: .medium))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Per-server card

    private func serverCard(_ snapshot: ServerStatusSnapshot) -> some View {
        MaryCard {
            VStack(alignment: .leading, spacing: .layer3) {
                HStack(spacing: .layer3) {
                    StatusDot(color: dotColor(snapshot.status))
                    Text(snapshot.kind.rawValue)
                        .font(.marySans(13, weight: .medium))
                    Text(statusLine(snapshot))
                        .font(.marySans(11))
                        .foregroundStyle(Color.maryInk.opacity(0.55))
                    Spacer()
                }
                if let detail = snapshot.detail {
                    Text(detail)
                        .font(.marySans(10))
                        .foregroundStyle(Color.maryInk.opacity(0.5))
                }
                HStack(spacing: .layer2) {
                    switch snapshot.status {
                    case .stopped, .notBuilt, .unhealthy:
                        if snapshot.binaryPath != nil {
                            Button("Start") { viewModel.startServer(snapshot.kind) }
                                .buttonStyle(.mary)
                        }
                    case .healthy, .launching, .external:
                        Button("Stop") { viewModel.stopServer(snapshot.kind) }
                            .buttonStyle(.maryQuiet)
                        Button("Restart") { viewModel.restartServer(snapshot.kind) }
                            .buttonStyle(.maryQuiet)
                    case .building:
                        EmptyView()
                    }
                    if snapshot.status != .building {
                        Button(snapshot.binaryPath == nil ? "Build" : "Rebuild") {
                            viewModel.build(snapshot.kind)
                        }
                        .buttonStyle(.maryQuiet)
                        .disabled(viewModel.buildingKinds.contains(snapshot.kind))
                    }
                    Spacer()
                }
                if snapshot.status == .external {
                    Text("Launched outside Mary — Stop still ends it.")
                        .font(.marySans(10))
                        .foregroundStyle(Color.maryInk.opacity(0.4))
                }
                if let tail = viewModel.buildTails[snapshot.kind], !tail.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(tail.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Color.maryInk.opacity(0.6))
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.layer2)
                    .background(Color.maryInk.opacity(0.04))
                }
                if snapshot.kind == .totem {
                    totemGraphRows
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Knowledge-graph growth + the extraction backend the node launches with.
    @ViewBuilder
    private var totemGraphRows: some View {
        if let stats = viewModel.graphStats {
            VStack(alignment: .leading, spacing: 2) {
                Text("Graph: \(stats.entityCount) entities · \(stats.relationshipCount) relationships")
                    .font(.marySans(11))
                    .foregroundStyle(Color.maryInk.opacity(0.6))
                if !stats.topEntities.isEmpty {
                    Text(stats.topEntities.prefix(4)
                        .map { "\($0.name) ×\($0.mentionCount)" }
                        .joined(separator: "  ·  "))
                        .font(.marySans(10))
                        .foregroundStyle(Color.maryInk.opacity(0.45))
                        .lineLimit(1)
                }
            }
        }
        HStack(spacing: .layer3) {
            Text("Extraction")
                .font(.marySans(11))
                .foregroundStyle(Color.maryInk.opacity(0.6))
            Picker("", selection: graphBackendBinding) {
                Text("Mistral API").tag("mistral")
                Text("On-device MLX").tag("mlx")
                Text("Keywords only").tag("keyword")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            Spacer()
        }
        Text("How Totem builds entities and relationships from what Mary deposits. Applies on the next Totem restart. MLX needs a Metal-enabled build; without one it silently degrades to keywords.")
            .font(.marySans(10))
            .foregroundStyle(Color.maryInk.opacity(0.4))
        HStack(spacing: .layer3) {
            Button("Clear Mary's context") { confirmClearContext = true }
                .buttonStyle(.maryQuiet)
                .disabled(viewModel.isClearing)
            Button("Clear everything") { confirmClearAll = true }
                .buttonStyle(.maryQuiet)
                .disabled(viewModel.isClearing)
            Spacer()
        }
        .confirmationDialog(
            "Clear Mary's deposited context? This removes project/context memory and the learned application schema — your saved memories stay. This can't be undone.",
            isPresented: $confirmClearContext
        ) {
            Button("Clear Mary's context", role: .destructive) { viewModel.clearMaryContext() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Clear everything in your totem? This removes ALL documents on this node owned by your account, including saved memories. This can't be undone.",
            isPresented: $confirmClearAll
        ) {
            Button("Clear everything", role: .destructive) { viewModel.clearEverything() }
            Button("Cancel", role: .cancel) {}
        }
        Text("Clearing Mary's context wipes the project lane and learned Ability lane. Node identity and storage paths stay in place; only Mary's contents go.")
            .font(.marySans(10))
            .foregroundStyle(Color.maryInk.opacity(0.4))
        if let notice = viewModel.clearNotice {
            Text(notice)
                .font(.marySans(10))
                .foregroundStyle(Color.maryInk.opacity(0.55))
        }
    }

    private var graphBackendBinding: Binding<String> {
        Binding(
            get: { config.state.totemGraphBackend },
            set: { backend in
                config.center.update.send(ConfigService.Update.Meta(totemGraphBackend: backend))
                var updated = config.state
                updated.totemGraphBackend = backend
                let nodeID = config.state.totemNodeID
                Task { await MaryRuntime.applyServers(config: updated, nodeID: nodeID) }
            }
        )
    }

    private func dotColor(_ status: ServerStatus) -> Color {
        switch status {
        case .healthy: return .green
        case .launching, .building: return .maryGold
        case .unhealthy: return .red
        case .stopped, .notBuilt: return .gray
        case .external: return .blue
        }
    }

    private func statusLine(_ snapshot: ServerStatusSnapshot) -> String {
        var parts: [String] = [snapshot.status.rawValue]
        if let pid = snapshot.pid { parts.append("pid \(pid)") }
        if let started = snapshot.startedAt {
            let minutes = Int(Date().timeIntervalSince(started) / 60)
            parts.append(minutes < 1 ? "just started" : "up \(minutes)m")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Account

    private var accountCard: some View {
        MaryCard {
            VStack(alignment: .leading, spacing: .layer3) {
                HStack(spacing: .layer3) {
                    SectionLabel("Seer account")
                    StatusDot(color: viewModel.isAuthenticated ? .green : .gray)
                    if let owner = viewModel.ownerID {
                        Text(owner)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.maryInk.opacity(0.45))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                }
                HStack(spacing: .layer2) {
                    TextField("email", text: $email)
                        .textFieldStyle(.roundedBorder)
                        .font(.marySans(12))
                    SecureField("password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .font(.marySans(12))
                    Button("Sign in") {
                        config.center.update.send(ConfigService.Update.Meta(
                            seerEmail: email, seerPassword: password))
                        viewModel.signIn(
                            email: email, password: password,
                            port: config.state.seerPort)
                    }
                    .buttonStyle(.mary)
                }
                if let notice = viewModel.authNotice {
                    Text(notice)
                        .font(.marySans(10))
                        .foregroundStyle(Color.red.opacity(0.7))
                }
                HStack(spacing: .layer3) {
                    Text("Chat model")
                        .font(.marySans(11))
                        .foregroundStyle(Color.maryInk.opacity(0.6))
                        .frame(width: 110, alignment: .leading)
                    TextField("Seer default (Inkling)", text: chatModelBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                }
                Text("Empty uses Seer's default. Thinking models deliberate before their first word — a lighter model here trades depth for response speed.")
                    .font(.marySans(10))
                    .foregroundStyle(Color.maryInk.opacity(0.4))
                Text("Signed in automatically at launch; tokens live only in memory.")
                    .font(.marySans(10))
                    .foregroundStyle(Color.maryInk.opacity(0.4))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Stack configuration

    private var stackConfigCard: some View {
        MaryCard {
            VStack(alignment: .leading, spacing: .layer3) {
                SectionLabel("Stack configuration")
                pathRow("Seer checkout", text: $seerPath)
                pathRow("Totem checkout", text: $totemPath)
                HStack(spacing: .layer3) {
                    portField("Seer port", text: $seerPortText)
                    portField("Totem port", text: $totemPortText)
                    Spacer()
                }
                HStack(spacing: .layer3) {
                    Text("Totem identity")
                        .font(.marySans(11))
                        .foregroundStyle(Color.maryInk.opacity(0.6))
                        .frame(width: 110, alignment: .leading)
                    Text(config.state.totemNodeID.isEmpty ? "adopted at first boot" : config.state.totemNodeID)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.maryInk.opacity(0.55))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(config.state.totemNodeID, forType: .string)
                    }
                    .buttonStyle(.maryQuiet)
                    Button("Regenerate…") { confirmRegenerate = true }
                        .buttonStyle(.maryQuiet)
                    Spacer()
                }
                Text("The identity names the on-disk database — regenerating starts an EMPTY totem; the old one stays on disk under the previous id.")
                    .font(.marySans(10))
                    .foregroundStyle(Color.maryInk.opacity(0.4))
                HStack {
                    Spacer()
                    Button("Apply & restart servers") { applyStackConfig() }
                        .buttonStyle(.mary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog(
            "Start a fresh totem identity? The current database stays on disk but Mary stops using it.",
            isPresented: $confirmRegenerate
        ) {
            Button("Regenerate identity", role: .destructive) {
                let fresh = UUID().uuidString
                config.center.update.send(ConfigService.Update.Meta(totemNodeID: fresh))
                applyStackConfig(nodeID: fresh)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func pathRow(_ label: String, text: Binding<String>) -> some View {
        HStack(spacing: .layer3) {
            Text(label)
                .font(.marySans(11))
                .foregroundStyle(Color.maryInk.opacity(0.6))
                .frame(width: 110, alignment: .leading)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
        }
    }

    private func portField(_ label: String, text: Binding<String>) -> some View {
        HStack(spacing: .layer2) {
            Text(label)
                .font(.marySans(11))
                .foregroundStyle(Color.maryInk.opacity(0.6))
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 64)
        }
    }

    private func applyStackConfig(nodeID: String? = nil) {
        let seerPort = Int(seerPortText) ?? config.state.seerPort
        let totemPort = Int(totemPortText) ?? config.state.totemPort
        config.center.update.send(ConfigService.Update.Meta(
            seerCheckoutPath: seerPath,
            totemCheckoutPath: totemPath,
            seerPort: seerPort,
            totemPort: totemPort))
        var updated = config.state
        updated.seerCheckoutPath = seerPath
        updated.totemCheckoutPath = totemPath
        updated.seerPort = seerPort
        updated.totemPort = totemPort
        let identity = nodeID ?? config.state.totemNodeID
        Task {
            await MaryRuntime.applyServers(config: updated, nodeID: identity)
            await MaryRuntime.localStack.stopAll()
            _ = await MaryRuntime.localStack.ensureRunning()
        }
    }

    // MARK: - Bindings

    private var seerEnabledBinding: Binding<Bool> {
        Binding(
            get: { config.state.seerEnabled },
            set: { enabled in
                config.center.update.send(ConfigService.Update.Meta(seerEnabled: enabled))
                Task {
                    await MaryRuntime.connectSeerToBrain(
                        chat: MaryRuntime.seerCarriesTurns(seerEnabled: enabled),
                        archiving: enabled,
                        stackEnabled: enabled)
                }
            }
        )
    }

    private var autoStartBinding: Binding<Bool> {
        Binding(
            get: { config.state.autoStartServers },
            set: { enabled in
                config.center.update.send(ConfigService.Update.Meta(autoStartServers: enabled))
            }
        )
    }

    private var chatModelBinding: Binding<String> {
        Binding(
            get: { config.state.seerChatModel },
            set: { model in
                config.center.update.send(ConfigService.Update.Meta(seerChatModel: model))
                var updated = config.state
                updated.seerChatModel = model
                let nodeID = config.state.totemNodeID
                Task { await MaryRuntime.applyServers(config: updated, nodeID: nodeID) }
            }
        )
    }
}
