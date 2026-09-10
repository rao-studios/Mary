//
//  RunningAppRoster.swift
//  Sand
//
//  WHAT: Every regular (Dock-visible) running app, as pickable rows.
//  IN:   NSWorkspace launch/terminate notifications
//  OUT:  TargetPickerView
//  PIN:  Same `.regular` filter Mary's own running-app pickers use
//        (AbilityStudioNewPackageSheet). Sand excludes itself: a wireframe of
//        the wireframe answers nothing.
//
import AppKit
import Foundation

struct RunningAppRow: Identifiable, Equatable {
    var id: pid_t { pid }
    var pid: pid_t
    var name: String
    var bundleID: String?
    var icon: NSImage?
}

@MainActor
final class RunningAppRoster: ObservableObject {
    @Published private(set) var apps: [RunningAppRow] = []

    private var launchObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?

    init() {
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        launchObserver = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        terminateObserver = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.refresh() } }
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        if let launchObserver { center.removeObserver(launchObserver) }
        if let terminateObserver { center.removeObserver(terminateObserver) }
    }

    func refresh() {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != selfPID }
            .map {
                RunningAppRow(
                    pid: $0.processIdentifier,
                    name: $0.localizedName ?? "(unnamed)",
                    bundleID: $0.bundleIdentifier,
                    icon: $0.icon)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
