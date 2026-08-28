//
//  WebCanvasSchema.swift
//  MaryFoundation
//
//  A PLACE ON THE WEB MARY CAN WORK IN — declared, not coded.
//
//  WHY THIS IS NOT A SURFACE ON A PLUGIN, which is where the other three
//  live. `proseSurface`, `mediaSurface` and `browserSurface` all describe an
//  APPLICATION: they hang off a plugin block, beside a bundle identifier, and
//  the runtime finds them by asking which application is in front. A web tool
//  has no bundle identifier and no process. It is reached THROUGH a browser
//  and is not the browser — Shadertoy is not Safari, and a package that
//  claimed Safari's identity in order to describe Shadertoy would collide
//  with the package that legitimately owns it.
//
//  So this sits beside `plugin` on the package itself: a package may teach
//  Mary an application, or a place on the web, or both.
//
//  THE FAMILY IS "A WEB TOOL THAT TAKES A BODY OF TEXT AND DOES SOMETHING
//  WITH IT" — a shader editor, a REPL, a diagram renderer, a paste site, a
//  regex tester. Every one of them is: go to this address, get past whatever
//  consent banner stands in the way, find the editor, replace what is in it,
//  press the run chord, and read the result back off the page. The shape is
//  identical; only the words differ, and the words are what this declares.
//
//  NOTHING HERE IS A SITE NAME. `address` is a URL a package author typed,
//  the way `bundleIdentifiers` is an id they typed — identity, not a compiled
//  fact about the web.
//
//  WHY THE VERDICT WORDS ARE DECLARED AND THE VERDICT RULE IS NOT. A caller
//  cannot tell success from failure by reading a page unless it knows which
//  words that page uses for each — but which of those words OUTRANK the
//  others is a rule about honesty, and belongs to Mary. See
//  `statusMarker`: a site that prints "Compiled in 0.0 secs" whether or not
//  the compile worked is offering a marker, not a verdict, and a package that
//  could redefine the ranking could make every run report success.
//

import Foundation

public struct WebCanvasSchema: Codable, Hashable, Sendable {

    /// Where the tool lives. http/https only, admitted at validation.
    public var address: String

    /// What this canvas calls the thing it takes — "shader", "snippet",
    /// "diagram". The word reaches the spoken sentence, so it is the
    /// package's to choose.
    public var contentNoun: String

    /// The most content this canvas is offered in one go. A package proposes
    /// and the validator bounds it: a paste larger than the editor can hold
    /// is a hang, not an error.
    public var contentLimitBytes: Int

    /// A substring the content MUST contain to be worth sending — a shader
    /// without an entry point cannot compile, and finding that out from the
    /// page costs a navigation and a paste. Empty means anything goes.
    public var requiredContentMarker: String?

    /// The chord that runs what has been placed. Option-Return on most web
    /// editors, but that is a convention rather than a rule.
    public var runChord: PluginChord

    /// Labels on the buttons that stand between arrival and the editor —
    /// cookie notices, consent dialogs. Pressed by label, so the words are
    /// the package's.
    public var consentLabels: [String]

    /// Phrases that appear on the page ONLY when the thing failed.
    ///
    /// POSITIVE EVIDENCE OF FAILURE, and the only kind of evidence this lane
    /// treats as decisive. Their absence proves nothing — a page may fail
    /// silently, or in words nobody listed.
    public var diagnosticPhrases: [String]

    /// A phrase the page shows whether or not the run succeeded.
    ///
    /// ⚠️ DECLARED SO IT CAN BE DISBELIEVED. Shadertoy prints "Compiled in
    /// 0.0 secs" on failure exactly as on success, so a reader that took it
    /// for a success signal would report every run as working. Naming it
    /// here is how a package says "this looks like good news and is not".
    public var statusMarker: String?

    /// Roles or labels that identify the editor when the page holds several
    /// text areas. Empty means "the first editable surface", which is right
    /// for a single-editor tool.
    public var editorHints: [String]

    public init(
        address: String,
        contentNoun: String,
        contentLimitBytes: Int,
        requiredContentMarker: String? = nil,
        runChord: PluginChord,
        consentLabels: [String] = [],
        diagnosticPhrases: [String] = [],
        statusMarker: String? = nil,
        editorHints: [String] = []
    ) {
        self.address = address
        self.contentNoun = contentNoun
        self.contentLimitBytes = contentLimitBytes
        self.requiredContentMarker = requiredContentMarker
        self.runChord = runChord
        self.consentLabels = consentLabels
        self.diagnosticPhrases = diagnosticPhrases
        self.statusMarker = statusMarker
        self.editorHints = editorHints
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case address, contentNoun, contentLimitBytes, requiredContentMarker
        case runChord, consentLabels, diagnosticPhrases, statusMarker, editorHints
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        address = try values.decode(String.self, forKey: .address)
        contentNoun = try values.decode(String.self, forKey: .contentNoun)
        contentLimitBytes = try values.decode(Int.self, forKey: .contentLimitBytes)
        requiredContentMarker = try values.decodeIfPresent(
            String.self, forKey: .requiredContentMarker)
        runChord = try values.decode(PluginChord.self, forKey: .runChord)
        consentLabels = try values.decodeIfPresent(
            [String].self, forKey: .consentLabels) ?? []
        diagnosticPhrases = try values.decodeIfPresent(
            [String].self, forKey: .diagnosticPhrases) ?? []
        statusMarker = try values.decodeIfPresent(String.self, forKey: .statusMarker)
        editorHints = try values.decodeIfPresent([String].self, forKey: .editorHints) ?? []
    }

    /// Hand-written; empty collections and absent optionals stay off the
    /// wire, because the package digest is taken over these exact bytes.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(address, forKey: .address)
        try container.encode(contentNoun, forKey: .contentNoun)
        try container.encode(contentLimitBytes, forKey: .contentLimitBytes)
        if let requiredContentMarker {
            try container.encode(requiredContentMarker, forKey: .requiredContentMarker)
        }
        try container.encode(runChord, forKey: .runChord)
        if !consentLabels.isEmpty {
            try container.encode(consentLabels, forKey: .consentLabels)
        }
        if !diagnosticPhrases.isEmpty {
            try container.encode(diagnosticPhrases, forKey: .diagnosticPhrases)
        }
        if let statusMarker { try container.encode(statusMarker, forKey: .statusMarker) }
        if !editorHints.isEmpty { try container.encode(editorHints, forKey: .editorHints) }
    }
}
