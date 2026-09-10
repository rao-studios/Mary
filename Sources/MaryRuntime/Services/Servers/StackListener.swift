//
//  StackListener.swift
//  MaryRuntime
//
//  WHAT: Identity of a Sewn/Thread Mary did not spawn: pid on the health
//        port whose path still ends in the expected binary.
//  IN:   LocalStackManager pid-file adoption / kill targeting
//  PIN:  Recycled pid or some other binary on 8080 is never a kill target.
//

import Foundation

package enum StackListener {

    /// One pid per line, as `lsof -t` prints. IPv4+IPv6 duplicates collapse.
    package static func parsePIDs(_ output: String) -> [pid_t] {
        let ids = output.split(whereSeparator: \.isNewline).compactMap { line -> pid_t? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let value = Int32(trimmed) else { return nil }
            return value
        }
        return Array(Set(ids)).sorted()
    }

    /// Keep live processes whose executable path is the named binary.
    package static func matching(
        listed: [pid_t],
        executableName: String,
        commandPath: (pid_t) -> String?
    ) -> [pid_t] {
        listed.filter { pid in
            commandPath(pid)?.hasSuffix("/\(executableName)") == true
        }
    }
}
