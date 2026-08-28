//
//  main.swift
//  GPUProbe — `mary-gpu-probe`
//
//  DOES THE ON-DEVICE ENGINE HAVE A GPU TO RUN ON? One question, asked before
//  a 4 GB model download rather than after it.
//
//    mary-gpu-probe            # read the search path
//    mary-gpu-probe --run      # and then actually execute on the GPU
//
//  WHY `--run` IS OPT-IN. MLX reports a missing metallib by throwing
//  `std::runtime_error` from C++, which is not a Swift error and not
//  catchable — it takes the process down. So the default pass reads the
//  search path and stops, and the operation runs only once a library has been
//  found, where it is expected to succeed. A probe that crashed on exactly the
//  broken setup it exists to diagnose would be worse than no probe.
//
//  This is the check that was missing. `make-app.sh` copied `mlx.metallib`
//  into the app "if present" and called `build-metallib.sh` "if present", and
//  when the script had not been ported the app assembled cleanly and died at
//  first use with four words: library not found.
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
