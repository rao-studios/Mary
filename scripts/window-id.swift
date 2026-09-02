#!/usr/bin/env swift
//
//  window-id.swift
//  Mary
//
//  WHAT: Prints the CGWindowID and title of every on-screen window owned by
//        the "Mary" process, optionally filtered by a title substring.
//  OUT:  scripts/layout-check.sh polls this until the window it wants exists.
//
//    swift scripts/window-id.swift ["Ability Studio"]
//

import CoreGraphics
import Foundation

let filter = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil

guard let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: AnyObject]] else {
    exit(1)
}

for window in list {
    guard (window[kCGWindowOwnerName as String] as? String) == "Mary" else { continue }
    let title = (window[kCGWindowName as String] as? String) ?? ""
    if let filter, !title.contains(filter) { continue }
    guard let number = window[kCGWindowNumber as String] as? Int else { continue }
    print("\(number)\t\(title)")
}
