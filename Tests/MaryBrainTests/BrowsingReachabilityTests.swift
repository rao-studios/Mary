//
//  BrowsingReachabilityTests.swift
//  MaryBrainTests
//
//  WHAT: The shipped browsing craft stays declared, exposed, and wired to a browser.
//  OUT:  browsing.mary, safari.mary, chrome.mary
//  PIN:  A DISCIPLINE NAMES NO APPLICATION, AND THAT IS THE MECHANISM, NOT AN OMISSION.
//        A browser acquires `browsing` by REALIZING one of its skills — the compiler
//        unions the ability of every package whose skill a profile realizes — and that
//        edge is what wakes the ambient layer's dormant browser workspace. Written down
//        as assertions because the alternative (naming the browsers in the discipline)
//        compiles, ships, and quietly breaks the rule that a craft outlives any one
//        application.
//

import Foundation
import Testing
@testable import MaryBrain
@testable import MaryFoundation

@Suite struct BrowsingReachabilityTests {

    /// Every verb the browsing craft offers, and what each is for.
    static let shipped: [SkillID] = [
        "browsing.current-page", "browsing.list-tabs", "browsing.describe-media",
        "browsing.control-media", "browsing.open-location", "browsing.navigate-back",
        "browsing.navigate-forward", "browsing.reload-page", "browsing.scroll-page",
        "browsing.new-tab",
    ]

    @Test func everyBrowsingSkillIsDeclaredAndExposed() throws {
        guard InstalledPackages.installed() != nil else { return }
        let package = try load("browsing")
        let skills = Dictionary(uniqueKeysWithValues: package.skills.map { ($0.id, $0) })

        for id in Self.shipped {
            #expect(package.ability.skills.contains(id), "\(id) is not listed by the Ability")
            let skill = try #require(skills[id], "\(id) is not declared")
            #expect(skill.modelExposure.enabled, "\(id) is hidden from the model")
            #expect(skill.modelExposure.invocationName != nil, "\(id) has no invocation name")
            #expect(!skill.requirements.capabilities.isEmpty, "\(id) requires no capability")
        }
    }

    /// THE CRAFT IS PORTABLE, so it names no browser. If this ever fails, someone has
    /// taught the discipline about a specific application and the next browser will need
    /// the discipline edited rather than a package written.
    @Test func theDisciplineNamesNoApplication() throws {
        guard InstalledPackages.installed() != nil else { return }
        let package = try load("browsing")
        #expect(package.ability.paradigm == .discipline)
        #expect(
            package.applicationAffinities.isEmpty,
            "browsing names an application; a discipline must not")
        #expect(package.plugin == nil, "a discipline carries no application plugin block")
    }

    /// AND BOTH BROWSERS PICK IT UP, by realizing one of its skills.
    @Test(arguments: ["safari", "chrome"]) func aBrowserExtendsBrowsing(_ name: String) throws {
        guard InstalledPackages.installed() != nil else { return }
        let package = try load(name)

        #expect(package.paradigm == .applicationExpertise)
        #expect(
            package.dependencies.contains { $0.packageID == "browsing" && !$0.optional },
            "\(name) does not require browsing")
        let plugin = try #require(package.plugin, "\(name) declares no plugin")
        #expect(
            plugin.realizations.contains { $0.skillID == "browsing.new-tab" },
            "\(name) realizes no browsing skill, so its profile never acquires the ability")
        #expect(plugin.webSurface != nil, "\(name) declares no browser shell")
        #expect(
            plugin.application.targetClasses.contains("web-page"),
            "\(name) does not claim the class the browsing skills are eligible on")
    }

    /// THE SHELL IS DECLARED PER BROWSER BECAUSE THE BROWSERS DISAGREE. If these ever
    /// match, someone has copied one package into the other and one of them is wrong.
    @Test func theTwoBrowsersDescribeDifferentControls() throws {
        guard InstalledPackages.installed() != nil else { return }
        let safari = try #require(try load("safari").plugin?.webSurface)
        let chrome = try #require(try load("chrome").plugin?.webSurface)

        #expect(safari.backLabel != chrome.backLabel)
        #expect(safari.addressFieldLabel != chrome.addressFieldLabel)
        // And where the page is differs too: one publishes a web area, the other does
        // not build one until an assistive client wakes it.
        #expect(safari.pageFrameSource != chrome.pageFrameSource)
        #expect(safari.urlSource != chrome.urlSource)
    }

    /// The page perception is declared, observed, and short-lived — a page changes.
    @Test func thePageContextPerceptionIsDeclared() throws {
        guard InstalledPackages.installed() != nil else { return }
        let package = try load("browsing")
        let perception = try #require(
            package.perceptions.first { $0.id == "perception.page-context" })
        #expect(perception.ownership == .observed)
        #expect(perception.freshnessSeconds <= 10)
        #expect(perception.valueType == "browsing.page-report")
    }

    private func load(_ name: String) throws -> MaryAbilityPackage {
        guard let abilities = InstalledPackages.installed() else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try AbilityPackageCodec.load(
            from: abilities.appendingPathComponent("\(name).mary"))
    }
}
