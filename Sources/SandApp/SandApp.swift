//
//  SandApp.swift
//  Sand
//
//  WHAT: Mary's bench. Pick a running application, watch a live wireframe of
//        its accessibility tree, then run one taught Skill against it and watch
//        the route that Skill takes through MaryComputerUse.
//  OUT:  SandRootView
//  PIN:  TWO HALVES, ONE PREMISE — the wireframe is what Mary SEES
//        (AXEngine reads, no pixels), the bench is what Mary DOES
//        (AbilityRuntime → hands → ComputerUseMonitor). Sand itself performs
//        no act: everything on the timeline was performed by the machine layer
//        on the runtime's behalf, which is what makes the trace trustworthy.
//        Ported from Bonnie's Clyde (Sources/ClydeApp), which is the wireframe
//        half of this app; the bench half is Mary's own.
//
import SwiftUI

struct SandApp: App {
    var body: some Scene {
        WindowGroup {
            SandRootView()
                .frame(minWidth: 1100, minHeight: 680)
        }
        .windowResizability(.contentMinSize)
    }
}
