//
//  ComputerUse.swift
//  MaryComputerUse
//
//  WHAT: The machine layer — everything that senses or drives this Mac.
//  OUT:  MaryPlugin adapters, and nothing above them.
//  PIN:  Two invariants, each pinned by a test in MaryComputerUseTests:
//        1. Accessibility/ imports nothing from Sight/, Hands/, Stage/ or
//           Process/. The tree read is the floor; everything else stands on it.
//        2. No target above MaryComputerUse posts an input event, performs an
//           Accessibility action, or captures pixels.
//
//  THE LANES, in the order a turn uses them:
//
//    Accessibility/  TIER 0. One bounded walk of a process's Accessibility
//                    tree into plain Sendable values. Read-only, one-shot,
//                    no streamer: Mary polls.
//                      AXTreeWalker → AXSnapshotBuilder → AXAppSnapshot
//                        → AXElementRoster → AXAmbientContext
//                    MaryPlugin's AmbientSurfaceBridge turns that artifact
//                    into the ambient store's tier-0 surface. One way.
//
//    Sight/          Derived reads over the tree — page elements, the declared
//                    text surface, the last-acted element — plus the one pixel
//                    read Mary is allowed (ScreenRegionCapture).
//
//    Hands/          The acts, by instrument: Keyboard (chords, typing),
//                    Pointer (move/click/drag/scroll, anchor capture),
//                    Elements (press/set/focus an Accessibility element),
//                    Windows (raise, full screen, restore), Menus, MediaKeys.
//
//    Stage/          Who holds the machine right now, and proving they do:
//                    activation with a verified frontmost pid, arbitration
//                    between observers, bounded waits, single-poller claims.
//
//    Process/        Subprocess. Mary-owned tools only, never a shell.
//
//    Monitor/        One ComputerUseMonitor every lane reports into, so an
//                    act and its refusal are both watchable.
//
@_exported import MaryAmbient
@_exported import MaryFoundation
