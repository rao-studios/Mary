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
        // The page itself — read what it OFFERS or what it SAYS, then act on
        // what it named.
        "browsing.read-page", "browsing.read-page-text",
        "browsing.click-on-page", "browsing.fill-in-page",
        "browsing.scroll-to-on-page", "browsing.adjust-on-page", "browsing.search-web",
        "browsing.interact-with-page",
        // The tabs a browser holds, and the words on the page in front. Round 8.
        "browsing.switch-tab", "browsing.close-tab", "browsing.find-in-page",
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

    /// THE LISTING IS EXHAUSTIVE. A verb added to the package and not to this list is a
    /// verb nothing here is checking, which is how the browsing lane grew a skill that
    /// was declared, unexposed, and unreachable for a week.
    @Test func nothingShipsUnlisted() throws {
        guard InstalledPackages.installed() != nil else { return }
        let package = try load("browsing")
        let unlisted = package.ability.skills.filter { !Self.shipped.contains($0) }
        #expect(
            unlisted.isEmpty,
            "browsing ships \(unlisted.map(\.rawValue).sorted()) which this test does not check")
    }

    /// THE CORPUS TEACHES EVERY VERB A PAGE NEEDS. A route fixture is the one place a
    /// package says, in a whole sentence, what a Skill is for — and browsing shipped none,
    /// so with an embedding index in place no sentence ever cleared the floor for any of
    /// these: a bench with Chrome on the stage offered "0 selected of 120" for "go to a
    /// fred again video on youtube". Every fixture names the class the Ability is eligible
    /// on, because `PackageRoutingFixtureTests` re-checks that gate per fixture.
    @Test func theSkillsAPageNeedsHaveRouteFixtures() throws {
        guard InstalledPackages.installed() != nil else { return }
        let package = try load("browsing")
        let routed = package.fixtures.filter { $0.expectedDisposition == "route" }
        let taught = Set(routed.compactMap(\.expectedSkill))
        let needed: [SkillID] = [
            "browsing.search-web", "browsing.open-location", "browsing.fill-in-page",
            "browsing.click-on-page", "browsing.read-page",
        ]
        for id in needed {
            #expect(taught.contains(id), "\(id.rawValue) has no route fixture")
        }
        for fixture in routed {
            #expect(
                fixture.targetClass == "web-page",
                "fixture \(fixture.id) names no web-page target class")
        }
    }

    /// THE VERBS THE CONFIDENCE LANE PEELS. `SpokenArgumentExtractor` strips one leading
    /// command phrase from the ability's OWN triggers, so a `search_web` dispatched with no
    /// model round receives "a fred again video on youtube" rather than the whole command.
    /// The extractor's suite mirrors these inline; this keeps the package and that mirror
    /// from drifting apart.
    @Test func theCommandPhrasesTheExtractorPeelsAreDeclared() throws {
        guard InstalledPackages.installed() != nil else { return }
        let phrases = Set(try load("browsing").ability.triggers.phrases)
        for verb in ["go to", "take me to", "find me", "look up", "pull up",
                     "search for", "search the web for"] {
            #expect(phrases.contains(verb), "\"\(verb)\" is not a browsing trigger phrase")
        }
    }

    /// "WATCH" IS A ONE-WORD COMMAND, so it lives among the single-word tokens the
    /// extractor's stage 3 strips outright, not the multi-word phrases above. Measured
    /// live: without it, "watch a fred again video on youtube" kept its verb and typed
    /// the whole sentence into the address bar.
    @Test func watchIsDeclaredAsALeadingCommandToken() throws {
        guard InstalledPackages.installed() != nil else { return }
        let tokens = Set(try load("browsing").ability.triggers.tokens)
        #expect(tokens.contains("watch"), "\"watch\" is not a browsing trigger token")
    }

    private func load(_ name: String) throws -> MaryAbilityPackage {
        guard let abilities = InstalledPackages.installed() else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try AbilityPackageCodec.load(
            from: abilities.appendingPathComponent("\(name).mary"))
    }
}
