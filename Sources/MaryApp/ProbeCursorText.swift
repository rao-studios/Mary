//
//  ProbeCursorText.swift
//  Mary
//
//  Inserts white "hello world" at the caret of whatever application is
//  frontmost:
//
//    swift run Mary --probe-cursor-text
//
//  Colored insertion goes through the pasteboard because neither the
//  accessibility API nor synthesized keystrokes carry text attributes — only
//  a rich-text paste does. The clipboard is saved and restored around the
//  paste the same way SelectionHandoffCoordinator does around its copy.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum ProbeCursorText {
    static func shouldRun() -> Bool {
        CommandLine.arguments.contains("--probe-cursor-text")
    }

    static func start() {
        Task { @MainActor in
            print("[accessibility] \(AXIsProcessTrusted())")
            print("[post-events] \(CGPreflightPostEventAccess())")
            let target = NSWorkspace.shared.frontmostApplication
            print("[frontmost] \(target?.bundleIdentifier ?? "nil")")
            guard let pid = target?.processIdentifier else {
                print("[cursor-text] FAILED: no frontmost application")
                exit(1)
            }
            guard await insert("hello world", color: .white, pid: pid) else {
                print("[cursor-text] FAILED: paste not issued")
                exit(1)
            }
            print("[cursor-text] pasted")
            exit(0)
        }
        RunLoop.main.run()
    }

    /// Writes `text` in `color` as RTF, pastes it into `pid`, then puts the
    /// user's clipboard back. Applications that only take plain text read the
    /// `.string` flavor and drop the color.
    @MainActor
    static func insert(_ text: String, color: NSColor, pid: pid_t) async -> Bool {
        let attributed = NSAttributedString(
            string: text, attributes: [.foregroundColor: color])
        guard let rtf = attributed.rtf(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [:])
        else { return false }

        let pasteboard = NSPasteboard.general
        let savedItems: [[NSPasteboard.PasteboardType: Data]] =
            (pasteboard.pasteboardItems ?? []).map { item in
                Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                    item.data(forType: type).map { (type, $0) }
                })
            }
        defer {
            pasteboard.clearContents()
            if !savedItems.isEmpty {
                let restored = savedItems.map { values -> NSPasteboardItem in
                    let item = NSPasteboardItem()
                    for (type, data) in values { item.setData(data, forType: type) }
                    return item
                }
                pasteboard.writeObjects(restored)
            }
        }

        pasteboard.declareTypes([.rtf, .string], owner: nil)
        guard pasteboard.setData(rtf, forType: .rtf) else { return false }
        pasteboard.setString(text, forType: .string)

        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(
                keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(
                keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else { return false }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(pid)
        keyUp.postToPid(pid)

        // A paste raises no changeCount to wait on, so settle before the defer
        // pulls the clipboard back out from under the target application.
        try? await Task.sleep(for: .milliseconds(400))
        return true
    }
}
