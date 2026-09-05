#!/usr/bin/env swift
//
//  window-id.swift
//  Mary
//
//  WHAT: Prints the CGWindowID and title of every on-screen window owned by a
//        named process, optionally filtered by a title substring.
//  OUT:  scripts/layout-check.sh polls this until the window it wants exists.
//  PIN:  THE OWNER IS AN ARGUMENT, defaulting to Mary. Sand is a second app with
//        its own bundle id and its own windows, and screenshotting a bench by
//        window id is how anything about it gets shown to anyone.
//
//    swift scripts/window-id.swift ["Ability Studio"] [Mary]
//    swift scripts/window-id.swift "" Sand
//

import CoreGraphics
import Foundation

let rawFilter = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil
// An empty first argument means "no title filter" — the way to reach the second
// argument without one.
let filter = (rawFilter?.isEmpty ?? true) ? nil : rawFilter
let owner = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "Mary"

guard let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: AnyObject]] else {
    exit(1)
}

for window in list {
    guard (window[kCGWindowOwnerName as String] as? String) == owner else { continue }
    let title = (window[kCGWindowName as String] as? String) ?? ""
    if let filter, !title.contains(filter) { continue }
    guard let number = window[kCGWindowNumber as String] as? Int else { continue }
    print("\(number)\t\(title)")
}
