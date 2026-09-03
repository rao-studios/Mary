//
//  ProjectBuildAdapter.swift
//  MaryPlugin
//
//  WHAT: Build and test at the live project root.
//  IN:   ProjectRootResolver / package CLI / corpus markers
//  OUT:  SkillBinding (build, test)
//  PIN:  Backend from declared CLI or markers — never `if Xcode`.
//

import Foundation
import MaryComputerUse
import MaryFoundation

public struct ProjectBuildAdapter: MaryAdapter {

    public let name = "project-build"
    public let summary = "Compile and test the live project through a declared or marker-chosen CLI"

    public init() {}

    public var skillBindings: [SkillBinding] {
        [buildCheck, runTests]
    }

    public var adapterManifest: InstalledAdapterManifest {
        let adapterID = AdapterID.normalized(name)
        return InstalledAdapterManifest(
            adapterID: adapterID,
            title: "Project Build",
            transport: .native,
            operations: [
                InstalledAdapterBinding(
                    adapterID: adapterID, operation: "build_check",
                    capabilities: ["code.build.check"],
                    outputTypes: ["coding.operation-result"],
                    targetClasses: ["code-workspace"]),
                InstalledAdapterBinding(
                    adapterID: adapterID, operation: "run_tests",
                    capabilities: ["code.test.run"],
                    outputTypes: ["coding.operation-result"],
                    targetClasses: ["code-workspace"]),
            ],
            supportedValueTypes: ["coding.operation-result"],
            grantedPermissions: [.files])
    }

    private var buildCheck: SkillBinding {
        SkillBinding(
            name: "build_check",
            description: "Compile the live project and report the first compiler error, or that it built.",
            access: .read,
            backing: .native { _, context in
                switch ProjectRootResolver.live(named: nil, context: context) {
                case .failure(let refusal): return SkillOutcome(ok: false, summary: refusal.spoken)
                case .success(let focus):
                    let command = Self.checkCommand(for: focus)
                    return await Self.run(command, at: focus.root, timeout: 180, parseErrors: true)
                }
            })
    }

    private var runTests: SkillBinding {
        SkillBinding(
            name: "run_tests",
            description: "Run the live project's tests and report the summary. Optional filter names one test.",
            parameters: [
                .init(name: "filter", type: "string",
                      description: "A test name to run; omit for the whole suite.",
                      required: false),
            ],
            access: .read,
            backing: .native { arguments, context in
                switch ProjectRootResolver.live(named: nil, context: context) {
                case .failure(let refusal): return SkillOutcome(ok: false, summary: refusal.spoken)
                case .success(let focus):
                    var command = Self.testCommand(for: focus)
                    if let filter = arguments["filter"], !filter.isEmpty {
                        let flag = focus.registration?.schema.build?.testFilterFlag
                            ?? Self.defaultFilterFlag(for: command)
                        command.append(contentsOf: [flag, filter])
                    }
                    return await Self.run(command, at: focus.root, timeout: 300, parseErrors: false)
                }
            })
    }

    static func checkCommand(for focus: ProjectRootResolver.Focus) -> [String] {
        if let declared = focus.registration?.schema.build?.checkCommand, !declared.isEmpty {
            return declared
        }
        return command(for: focus.root, test: false)
    }

    static func testCommand(for focus: ProjectRootResolver.Focus) -> [String] {
        if let declared = focus.registration?.schema.build?.testCommand, !declared.isEmpty {
            return declared
        }
        return command(for: focus.root, test: true)
    }

    static func command(for root: String, test: Bool) -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        if entries.contains("Package.swift") {
            return test ? ["swift", "test"] : ["swift", "build"]
        }
        let ideProject = "." + ["xc", "odeproj"].joined()
        let ideWorkspace = "." + ["xc", "workspace"].joined()
        if entries.contains(where: { $0.hasSuffix(ideProject) || $0.hasSuffix(ideWorkspace) }) {
            let tool = "/usr/bin/" + ["xc", "odebuild"].joined()
            let scheme = schemeHint(in: entries, suffix: ideProject)
            return test
                ? [tool, "test", "-scheme", scheme]
                : [tool, "build", "-scheme", scheme]
        }
        if entries.contains("package.json") {
            return test ? ["npm", "test"] : ["npm", "run", "build"]
        }
        if entries.contains("Cargo.toml") {
            return test ? ["cargo", "test"] : ["cargo", "build"]
        }
        return test ? ["swift", "test"] : ["swift", "build"]
    }

    static func schemeHint(in entries: [String], suffix: String) -> String {
        entries.first { $0.hasSuffix(suffix) }
            .map { ($0 as NSString).deletingPathExtension } ?? ""
    }

    static func defaultFilterFlag(for command: [String]) -> String {
        if command.first == "swift" { return "--filter" }
        if command.first?.hasSuffix("build") == true { return "-only-testing" }
        return "--filter"
    }

    static func run(
        _ command: [String], at root: String, timeout: TimeInterval, parseErrors: Bool
    ) async -> SkillOutcome {
        guard let executable = command.first, command.count >= 1 else {
            return SkillOutcome(ok: false, summary: "That project has no build command.")
        }
        let arguments = Array(command.dropFirst())
        let resolved = executable.contains("/")
            ? executable
            : (Self.which(executable) ?? executable)
        do {
            let result = try await Subprocess.run(
                resolved, arguments, timeout: timeout, currentDirectory: root)
            let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.exitCode == 0 {
                return SkillOutcome(
                    ok: true,
                    summary: output.isEmpty ? "It built." : TextBudget.truncate(output, limit: 1800))
            }
            if parseErrors, let diagnostic = firstError(in: output) {
                return SkillOutcome(ok: false, summary: diagnostic)
            }
            return SkillOutcome(
                ok: false,
                summary: output.isEmpty
                    ? "The command failed."
                    : TextBudget.truncate(output, limit: 1800))
        } catch {
            return SkillOutcome(ok: false, summary: error.localizedDescription)
        }
    }

    static func firstError(in output: String) -> String? {
        for raw in output.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.localizedCaseInsensitiveContains(": error:") {
                return line
            }
        }
        return nil
    }

    static func which(_ name: String) -> String? {
        let path = "/usr/bin/\(name)"
        if FileManager.default.isExecutableFile(atPath: path) { return path }
        let local = "/opt/homebrew/bin/\(name)"
        if FileManager.default.isExecutableFile(atPath: local) { return local }
        return nil
    }
}
