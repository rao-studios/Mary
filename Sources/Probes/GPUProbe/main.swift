//
//  main.swift
//  GPUProbe — `mary-gpu-probe`
//
//  WHAT: Does the on-device engine have a GPU (before a 4 GB download).
//  OUT:  CLI: mary-gpu-probe [--run]
//  PIN:  --run is opt-in; missing metallib is an uncatchable C++ abort.
//

import Foundation
import MaryBrain

let wantsRun = CommandLine.arguments.dropFirst().contains("--run")
let report = MaryGPU.report()

print("\nwhere MLX will look")
print(String(repeating: "─", count: 30))
for candidate in report.searched {
    print("  \(candidate.exists ? "✓" : "·")  \(candidate.rung)")
    print("       \(candidate.path)")
}

guard let found = report.found else {
    print("\n  ✗  no Metal library on any rung.\n")
    print("     \(MaryGPU.remedy())\n")
    exit(1)
}

let size = (try? FileManager.default.attributesOfItem(atPath: found.path)[.size]) as? Int ?? 0
print("\n  ✓  MLX will load: \(found.rung)")
print(String(format: "     %@ (%.1f MB)", found.path, Double(size) / 1_048_576))

guard wantsRun else {
    print("\n     Pass --run to execute on the GPU and prove it loads.\n")
    exit(0)
}

print("\nrunning on the GPU")
print(String(repeating: "─", count: 30))
let elapsed = await MaryGPU.exercise()
switch elapsed {
case .success(let detail):
    print("  ✓  \(detail)\n")
    exit(0)
case .failure(let message):
    print("  ✗  \(message)\n")
    exit(1)
}
