//
//  StackListener.swift
//  Mary
//
//  How Mary names a Seer or Totem it did not spawn: the process listening on
//  the health port, whose path still ends in the expected binary. The same
//  identity check pid-file adoption uses — a recycled pid or some other
//  binary on 8080 is never a kill target.
//

import Foundation

package enum StackListener {

    /// One pid per line, as `lsof -t` prints. Duplicates happen when the same
    /// process listens on IPv4 and IPv6; they collapse.
    package static func parsePIDs(_ output: String) -> [pid_t] {
        let ids = output.split(whereSeparator: \.isNewline).compactMap { line -> pid_t? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let value = Int32(trimmed) else { return nil }
            return value
        }
        return Array(Set(ids)).sorted()
    }

    /// Keep only live processes whose executable path is the named binary.
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
