//
//  AbilityLibrary+Discovery.swift
//

import ApplicationServices
import MaryFoundation
import CryptoKit
import Darwin
import Foundation
import os

extension AbilityLibrary {

    // MARK: - Discovery

    struct Discovery {
        var records: [AbilityPackageRecord]
        var issues: [SchemaIssue]
        var filesRead: Int
    }

    func discover(in locations: [AbilityPackageLocation]) -> Discovery {
        var chosen: [PackageID: (priority: Int, record: AbilityPackageRecord)] = [:]
        var issues: [SchemaIssue] = []
        var filesRead = 0
        let sortedLocations = locations.sorted { $0.priority < $1.priority }
        for location in sortedLocations {
            guard let files = try? fileManager.contentsOfDirectory(
                at: location.directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles])
            else { continue }
            for url in files.filter({ $0.pathExtension.lowercased() == "mary" })
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                filesRead += 1
                do {
                    let data = try AbilityPackageCodec.contents(of: url)
                    let package = try AbilityPackageCodec.decode(data)
                    let validation = AbilityPackageValidator.validate(package)
                    let record = AbilityPackageRecord(
                        package: package,
                        source: location.source,
                        sourceURL: url,
                        validation: validation,
                        rawData: data)
                    if let current = chosen[package.package.id],
                       current.priority == location.priority {
                        issues.append(.init(
                            severity: .error,
                            code: "duplicate-source-package",
                            path: url.path,
                            message: "Two packages with id \(package.package.id.rawValue) exist at one precedence level (\(current.record.package.package.version) and \(package.package.version)); filename order cannot choose an active version."))
                    } else if chosen[package.package.id]?.priority ?? Int.min <= location.priority {
                        chosen[package.package.id] = (location.priority, record)
                    }
                } catch {
                    issues.append(.init(
                        severity: .error,
                        code: "package-load",
                        path: url.path,
                        message: error.localizedDescription))
                }
            }
        }
        return Discovery(
            records: chosen.values.map(\.record),
            issues: issues,
            filesRead: filesRead)
    }

}
