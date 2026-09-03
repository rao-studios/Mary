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

NSApplication.shared.setActivationPolicy(.regular)
SandApp.main()
