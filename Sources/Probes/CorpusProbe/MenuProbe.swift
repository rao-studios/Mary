//
//  MenuProbe.swift
//  CorpusProbe
//
//  WHAT AN APPLICATION'S MENUS ACTUALLY SAY — measured before a package
//  declares a path through them.
//
//  A menu path in a declaration is a claim about somebody else's program:
//  that this menu exists, under this name, with these items under it, in the
//  version installed here. Every one of those can be false, and a path that
//  is wrong fails at the moment a ceremony runs — which is the worst moment,
//  because by then the user has asked for something.
//
//  So this reads the menus first. It also answers a question the predecessor
//  recorded and could not settle: it searched for `Documents → Status` and
//  `Documents → Label` and found neither, and could not tell whether they
//  were absent from that build or merely absent while no project was open,
//  because the probe ran with none. This one can be run either way.
//
//    mary-corpus-probe menus --app Scrivener
//    mary-corpus-probe menus --app Scrivener --path "Documents/Move To"
//

import AppKit
import ApplicationServices
import Foundation
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
        // EXACT NAME, THEN PREFIX — the same ladder `mary-ax-probe` climbs,
        // and it earns its keep immediately: Scrivener's localized name is
        // "Scrivener 3", so an exact match reports a running application as
        // absent.
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
            // THE PREDECESSOR'S OPEN QUESTION, kept in the roster so the
            // answer stays measured rather than remembered: neither exists in
            // Scrivener 3 — Status and Label live in the Inspector panel,
            // which is not a menu at all.
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
            // ENABLED IS PART OF THE ANSWER. A command that exists and is
            // greyed out is a different fact from one that is missing, and a
            // package author reading this needs to know which they are
            // looking at — "Move To" is disabled with nothing selected.
            print("""
              ✓ \(shown)\(enabled == false ? "  [DISABLED]" : "")\
            \(children.isEmpty ? "" : "  → \(children.prefix(40).joined(separator: ", "))")\
            \(children.count > 40 ? " … +\(children.count - 40)" : "")
            """)
        }
    }
}
