//
//  MenuProbe.swift
//  CorpusProbe
//
//  WHAT: Measure an application's menus before a package declares a path through them.
//  OUT:  CLI: mary-corpus-probe menus --app … [--path …]
//

import AppKit
import ApplicationServices
import Foundation
import MaryComputerUse
import MaryPlugin

enum MenuProbe {

    static func shouldRun(_ arguments: [String]) -> Bool {
        arguments.contains("menus")
    }

    static func run(_ arguments: [String]) async {
        func value(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count
            else { return nil }
            return arguments[index + 1]
        }

        guard AXIsProcessTrusted() else {
            print("Accessibility is not granted for this binary. Use ./scripts/dev.sh.")
            exit(1)
        }

        let name = value("--app") ?? "Scrivener"
        // Exact name, then prefix (Scrivener 3 is not "Scrivener").
        let wanted = name.lowercased()
        guard let application = NSWorkspace.shared.runningApplications.first(where: {
            ($0.localizedName ?? "").lowercased() == wanted
        }) ?? NSWorkspace.shared.runningApplications.first(where: {
            ($0.localizedName ?? "").lowercased().hasPrefix(wanted)
        }) else {
            print("\(name) isn't running.")
            exit(1)
        }
        let pid = application.processIdentifier
        print("▸ \(application.localizedName ?? name) (pid \(pid))")

        let top = ApplicationMenuDriver.topLevelTitles(pid: pid)
        print("  menus       \(top.joined(separator: ", "))")

        if let requested = value("--path") {
            let path = requested.split(separator: "/").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            report(path: path, pid: pid)
            return
        }

        // THE PATHS A SCRIVENER-SHAPED PACKAGE WANTS, checked one level at a
        // time so a miss says which level was missing rather than "no".
        for path in [
            ["Documents"],
            ["Documents", "Move To"],
            ["Documents", "Split"],
            ["Documents", "Split", "at Selection"],
            ["Documents", "Group"],
            ["Documents", "Convert"],
            // Status/Label are Inspector, not menus; keep measuring absence.
            ["Documents", "Status"],
            ["Documents", "Label"],
            ["Documents", "Move to Trash"],
            ["Project", "New Text"],
            ["Project", "New Folder"],
            ["File", "Save"],
        ] {
            report(path: path, pid: pid)
        }
    }

    private static func report(path: [String], pid: pid_t) {
        let shown = path.joined(separator: " → ")
        switch ApplicationMenuDriver.locate(path: path, pid: pid) {
        case .failure(let failure):
            print("  ✗ \(shown)  — \(failure)")
        case .success(let item):
            let enabled = AX.number(item, kAXEnabledAttribute)?.boolValue
            let children = ApplicationMenuDriver.titles(under: path, pid: pid)
            // Enabled vs missing; "Move To" is disabled with nothing selected.
            print("""
              ✓ \(shown)\(enabled == false ? "  [DISABLED]" : "")\
            \(children.isEmpty ? "" : "  → \(children.prefix(40).joined(separator: ", "))")\
            \(children.count > 40 ? " … +\(children.count - 40)" : "")
            """)
        }
    }
}
