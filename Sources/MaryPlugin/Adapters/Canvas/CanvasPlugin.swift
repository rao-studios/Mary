//
//  CanvasPlugin.swift
//  MaryPlugin
//
//  WHAT: Mary's canvas as a Skill — show a page she authored, take it down.
//  IN:   CanvasService
//  OUT:  present_page / dismiss_page
//  PIN:  A FACULTY, NOT AN APPLICATION. Catalogued like window management;
//        names no app; `canvas.mary` routes it. The page is the model's own
//        composition, so this never takes the no-model lane.
//

import Foundation
import MaryFoundation

public struct CanvasPlugin: MaryAdapter {
    public static let adapterID = "canvas"

    public let name = Self.adapterID
    public let summary = "Show a page Mary drew — a chart, a note, a mood — in a window of her own, and take it down."
    public let abilities: Set<AbilityID> = [.canvas]
    public let applicationAliases: Set<String> = ["canvas"]

    private let service: CanvasService

    public init(service: CanvasService = .live) {
        self.service = service
    }

    public var promptFragment: String? {
        """
        The Canvas Ability's present_page Skill shows a whole HTML page you wrote, in \
        a window of Mary's own, when words would not do — a table, a chart, a \
        diagram. One page at a time; dismiss_page takes it down. Never for something \
        the user can already see, and never as a place to act in.
        """
    }

    public var servedAttention: AmbientAttention? { nil }

    public var adapterManifest: InstalledAdapterManifest {
        let adapterID = AdapterID(Self.adapterID)
        func operation(_ name: String, capability: CapabilityID) -> InstalledAdapterBinding {
            InstalledAdapterBinding(
                adapterID: adapterID,
                operation: name,
                capabilities: [capability],
                inputTypes: [],
                outputTypes: [],
                targetClasses: [])
        }
        return InstalledAdapterManifest(
            adapterID: adapterID,
            title: "Canvas",
            transport: .native,
            claimCoverage: .complete,
            operations: [
                operation("present_page", capability: "canvas.present"),
                operation("dismiss_page", capability: "canvas.dismiss"),
            ],
            supportedValueTypes: [])
    }

    public var skillBindings: [SkillBinding] {
        [presentPage, dismissPage]
    }

    private var presentPage: SkillBinding {
        SkillBinding(
            name: "present_page",
            description: "Show a complete HTML page you wrote in a window of Mary's own — a chart, a table, a diagram, a card. Self-contained HTML only: inline CSS and script, no external resources. Use when a picture or layout says it better than speech.",
            parameters: [
                .init(name: "html", type: "string",
                      description: "The whole page, self-contained. Inline everything; nothing is fetched.",
                      required: true),
                .init(name: "title", type: "string",
                      description: "A short name for the page, spoken back and shown nowhere.",
                      required: true),
                .init(name: "placement", type: "string",
                      description: "full_screen for the whole screen, panel for a centred window. Defaults to panel.",
                      required: false, enumValues: ["full_screen", "panel"]),
            ],
            access: .tweak,
            backing: .native { [service] arguments, _ in
                guard let html = arguments["html"], !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return SkillOutcome(ok: false, summary: "What should the page show?")
                }
                let title = arguments["title"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                let placement = arguments["placement"].flatMap(CanvasPlacement.init(spoken:)) ?? .panel
                let page = CanvasPage(title: title?.isEmpty == false ? title! : "Untitled", html: html)
                // ONE PAGE AT A TIME for the Skill. A plugin with a beat asks the
                // service directly and keeps several; a page the model shows
                // replaces the last one.
                await service.dismissAll()
                switch await service.present(page, placement: placement) {
                case .failure(let refusal):
                    return SkillOutcome(ok: false, summary: refusal.summary)
                case .success(let receipt):
                    return SkillOutcome(
                        ok: true,
                        summary: "Showing \(page.title). It steps aside if you ask me to do something else on screen.",
                        landed: receipt.ready || receipt.timedOut)
                }
            },
            stage: true)
    }

    private var dismissPage: SkillBinding {
        SkillBinding(
            name: "dismiss_page",
            description: "Take down whatever Mary is showing on her canvas.",
            access: .tweak,
            backing: .native { [service] _, _ in
                guard await service.dismissAll() else {
                    return SkillOutcome(ok: true, summary: CanvasRefusal.nothingShowing.summary)
                }
                return SkillOutcome(ok: true, summary: "Closed it.", landed: true)
            })
    }
}
