//
//  SandLaunchOptions.swift
//  Sand
//
//  WHAT: Start already pointed at something.
//  OUT:  SandRootView's opening phase, and one optional run
//  PIN:  A BENCH THAT CANNOT BE RE-RUN THE SAME WAY IS A STORY, NOT EVIDENCE.
//        These arguments exist so a run is repeatable — same target, same
//        invocation, same arguments — from a script or a launch config.
//        `--run` PERFORMS THE ABILITY. It is opt-in, never implied by
//        `--target`, because opening a bench should never be the same gesture
//        as pressing a key in somebody's document.
//
//    ./scripts/sand.sh --target com.apple.iCal
//    ./scripts/sand.sh --target com.apple.iCal --run calendar_go_today
//    ./scripts/sand.sh --target com.apple.Music --say "pause the music"
//    ./scripts/sand.sh --target com.apple.Music --say "play a playlist" --auto
//    ./scripts/sand.sh --target com.apple.TextEdit --run textedit_save_document \
//        --arg app=textedit
//    ./scripts/sand.sh --target com.google.Chrome --read-page
//    ./scripts/sand.sh --target com.google.Chrome --read-page \
//        --say "open the first result" --auto
//
import Foundation

struct SandLaunchOptions {
    /// Bundle id of the application to watch. Nothing is picked without it.
    var targetBundleID: String?
    /// Invocation to dispatch once the target is on the stage. Opt-in.
    var run: String?
    /// An utterance to run through the real turn loop. Opt-in, like `--run`:
    /// a turn dispatches for real if routing decides it should.
    var say: String?
    /// Answer the model's round automatically with the first offered skill and
    /// no arguments. Only meaningful with `--say`, and deliberately separate:
    /// asking Mary something is not the same as agreeing in advance to
    /// whatever she proposes.
    var auto = false
    /// Read the page once the stage is up. Only meaningful for a browser, and opt-in
    /// like every other verb here: a read claims the stage and moves the pointer, which
    /// is not something opening a bench should do on its own.
    var readPage = false
    /// `--arg name=value`, applied to BOTH lanes: the direct run's arguments, and the
    /// skill `--auto` answers with (filtered there to what that skill declares).
    var arguments: [String: String] = [:]

    static let current = SandLaunchOptions(CommandLine.arguments)

    init(_ argv: [String] = CommandLine.arguments) {
        var index = 1
        while index < argv.count {
            let flag = argv[index]
            let value = index + 1 < argv.count ? argv[index + 1] : nil
            switch flag {
            case "--target":
                targetBundleID = value
                index += 2
            case "--run":
                run = value
                index += 2
            case "--say":
                say = value
                index += 2
            case "--auto":
                auto = true
                index += 1
            case "--read-page":
                readPage = true
                index += 1
            case "--arg":
                // name=value. A value containing "=" keeps it: only the first
                // separator is structural.
                if let value, let split = value.firstIndex(of: "=") {
                    arguments[String(value[value.startIndex..<split])] =
                        String(value[value.index(after: split)...])
                }
                index += 2
            default:
                index += 1
            }
        }
    }
}
