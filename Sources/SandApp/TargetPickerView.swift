//
//  TargetPickerView.swift
//  Sand
//
//  WHAT: Which application to watch.
//  IN:   RunningAppRoster + the expertises the runtime loaded
//  OUT:  onPick(row) → the stage
//  PIN:  A row that Mary has been TAUGHT is badged, because that is the row
//        whose route through MaryComputerUse this app exists to show. Every
//        other app is still watchable — the wireframe needs no package.
//
import SwiftUI

struct TargetPickerView: View {
    @StateObject private var roster = RunningAppRoster()
    @ObservedObject var host: SandRuntimeHost
    let onPick: (RunningAppRow) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Pick a running app")
                    .font(.title2.bold())
                Spacer()
                Button {
                    roster.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
            }
            .padding()

            List(roster.apps) { row in
                Button {
                    onPick(row)
                } label: {
                    HStack(spacing: 10) {
                        if let icon = row.icon {
                            Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name)
                            if let bundleID = row.bundleID {
                                Text(bundleID)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if let package = host.package(forBundleID: row.bundleID) {
                            Text(package.title)
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.accentColor.opacity(0.18)))
                                .help("Mary has an expertise for this application")
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
