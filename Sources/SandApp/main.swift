//
//  main.swift
//  Sand
//
//  WHAT: The entry point.
//  PIN:  SPM executables launch as background processes. Setting `.regular`
//        before `main()` makes this a real foreground app with a dock icon and
//        a window — same reason Sources/MaryApp/main.swift does it.
//
import AppKit
import Darwin

// LINE-BUFFERED STDOUT. A trip run prints one verdict line per leg and is
// read through a pipe by whatever drives the round; stdio block-buffers a
// pipe, and a bench that never exits never flushes, so the verdicts were
// lost with the process. Measured: three trips ran, recorded, and printed
// nothing past the build.
setvbuf(stdout, nil, _IOLBF, 0)

NSApplication.shared.setActivationPolicy(.regular)
SandApp.main()
