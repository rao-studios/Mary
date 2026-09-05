//
//  MediaSurfaceAdapter.swift
//  MaryPlugin
//
//  WHAT: Skills a declared player answers (now_playing, transport, catalog, playlists).
//  PIN:  No player named. rate_track / library search stay out (no metadata lane).

import AppKit
import Foundation
import MaryAmbient
import MaryComputerUse
import MaryFoundation

public struct MediaSurfaceAdapter: MaryAdapter {

    public let name = "media-surface"
    public let summary =
        "reports what a media player is playing and drives playback for players that declare their transport"

    private let support: MediaSurfaceSupport
    private let catalog: any MediaCatalogSearching

    public init(
        support: MediaSurfaceSupport = .shared,
        catalog: any MediaCatalogSearching = ITunesMediaCatalogSearch()
    ) {
        self.support = support
        self.catalog = catalog
    }

    public var skillBindings: [SkillBinding] {
        [nowPlaying, controlPlayback, searchCatalog, playFromCatalog,
         listPlaylists, findPlaylist, playPlaylist, shufflePlaylist]
    }

    /// WHAT THIS ADAPTER REACHES, SAID ONCE — because the only sentence in the
    /// whole system prompt about pausing anything used to be the browsing
    /// adapter's, and it told the model not to do this.
    ///
    /// PIN: MEASURED, AND IT IS MOST OF WHY "can you pause the music" NEVER
    /// WORKED. `WebSurfaceAdapter.promptFragment` said "never the system media
    /// keys, which reach whatever holds now-playing" — which is precisely and
    /// only what `control_playback` does. With two near-identically described
    /// transport skills offered and standing prose arguing against one of them,
    /// a small model picked the other or called nothing at all. Bonnie carried
    /// exactly this fragment, for exactly this reason; the port dropped it.
    public var promptFragment: String? {
        """
        control_playback drives whatever holds now-playing — the music app, a \
        podcast, a video playing in some other window — so pause, play, next \
        and previous for THE MUSIC, or for playback in general, always go \
        there. control_media is only for a video inside a page you are \
        driving. Say what played.
        """
    }

    /// Typed handshake, declared rather than defaulted.
    /// PIN: operations must implement `media-player` or inventory refuses them.
    public var adapterManifest: InstalledAdapterManifest {
        let adapterID = AdapterID.normalized(name)
        func operation(
            _ name: String,
            capability: CapabilityID,
            input: ValueTypeID,
            output: ValueTypeID,
            // MEDIA-PLAYER OR NOTHING, per operation rather than adapter-wide: the two
            // catalog operations reach the iTunes Search endpoint and target no application
            // at all, and claiming a class they do not drive would be the same untruth in
            targets: [String] = ["media-player"],
            observesTransport: Bool = true
        ) -> InstalledAdapterBinding {
            InstalledAdapterBinding(
                adapterID: adapterID,
                operation: name,
                capabilities: [capability],
                inputTypes: [input],
                outputTypes: [output],
                observesPerceptions: observesTransport ? ["perception.player-transport"] : [],
                targetClasses: targets)
        }
        return InstalledAdapterManifest(
            adapterID: adapterID,
            title: "Media Surface",
            transport: .accessibility,
            operations: [
                operation(
                    "now_playing",
                    capability: "player.transport.read",
                    input: "multimedia.player-query",
                    output: "multimedia.now-playing-report"),
                operation(
                    "control_playback",
                    capability: "player.transport.control",
                    input: "multimedia.transport-request",
                    output: "multimedia.operation-result"),
                operation(
                    "search_music",
                    capability: "catalog.search",
                    input: "multimedia.catalog-query",
                    output: "multimedia.catalog-results",
                    targets: [],
                    observesTransport: false),
                operation(
                    "play_music",
                    capability: "catalog.open",
                    input: "multimedia.catalog-query",
                    output: "multimedia.operation-result",
                    // The Skill's own binding names no class, so this stays
                    // blank to match it: play_music opens a Store URL and only
                    // then presses the page's play control.
                    targets: []),
                operation(
                    "list_playlists",
                    capability: "library.playlists.read",
                    input: "multimedia.player-query",
                    output: "multimedia.catalog-results"),
                operation(
                    "find_playlist",
                    capability: "library.playlists.read",
                    input: "multimedia.player-query",
                    output: "multimedia.catalog-results"),
                operation(
                    "play_playlist",
                    capability: "library.playlists.play",
                    input: "multimedia.player-query",
                    output: "multimedia.operation-result"),
                operation(
                    "shuffle_playlist",
                    capability: "library.playlists.play",
                    input: "multimedia.player-query",
                    output: "multimedia.operation-result"),
            ],
            providesPerceptions: ["perception.player-transport"],
            supportedValueTypes: [
                "multimedia.player-query",
                "multimedia.now-playing-report",
                "multimedia.transport-request",
                "multimedia.operation-result",
                "multimedia.catalog-query",
                "multimedia.catalog-results",
            ],
            // WHAT THE MACHINE ACTUALLY GRANTED is not this adapter's to decide; these name
            // the two boundaries its operations cross, and the Capability schemas requiring
            // them are checked against this list.
            grantedPermissions: [.accessibility, .network])
    }

    // MARK: - Reading

    private var nowPlaying: SkillBinding {
        SkillBinding(
            name: "now_playing",
            description: "Say what a media player is playing right now, and whether it is playing, shuffling or repeating.",
            parameters: [
                .init(
                    name: "app", type: "string",
                    description: "Which player. Omit for the one that's running.",
                    required: false),
            ],
            access: .read,
            backing: .native { arguments, _ in
                guard let (registration, pid) = support.resolve(arguments["app"]) else {
                    return notRunning(arguments["app"])
                }
                guard let reading = MediaSurfaceAX.read(pid: pid, registration: registration) else {
                    return SkillOutcome(
                        ok: false,
                        summary: "I couldn't read \(registration.displayName)'s player just now.")
                }
                return SkillOutcome(
                    ok: true,
                    summary: Self.spoken(reading, registration: registration),
                    archivePolicy: .stateSnapshot,
                    // NOTHING PLAYING IS A MISS, not a failure. The read worked; there is
                    // simply no answer to give, and a turn that says so is more useful than
                    // one that reports an error against a player sitting quietly.
                    foundNothing: reading.title == nil && reading.isPlaying != true,
                    target: reading.element,
                    adapterTrail: ["media-surface"],
                    applicationID: registration.applicationID)
            })
    }

    /// The spoken answer. Absent facts are LEFT OUT rather than guessed —
    /// a player whose transport hides its shuffle control is not a player
    /// that is not shuffling.
    public static func spoken(
        _ reading: MediaSurfaceAX.Reading, registration: MediaSurfaceRegistration
    ) -> String {
        let noun = registration.noun
        guard let title = reading.title else {
            if reading.isPlaying == true {
                return "\(registration.displayName) is playing, but isn't saying what."
            }
            return "Nothing is playing in \(registration.displayName)."
        }
        // PARENTHESES, NOT A DASH, and the reason is the data: the subtitle is already
        // dash-joined by the player ("Enfant Sauvage.
        var sentence = reading.isPlaying == false
            ? "Paused on \"\(title)\""
            : "Playing \"\(title)\""
        if let subtitle = reading.subtitle, !subtitle.isEmpty {
            sentence += " (\(subtitle))"
        }
        sentence += " in \(registration.displayName)"
        if let position = reading.position, position > 0.005 {
            sentence += String(format: ", %.0f%% through", position * 100)
        }
        sentence += "."
        var modes: [String] = []
        if reading.isShuffling == true { modes.append("shuffle") }
        if reading.isRepeating == true { modes.append("repeat") }
        if !modes.isEmpty {
            sentence += " \(modes.joined(separator: " and ").capitalizedFirst) is on."
        }
        _ = noun
        return sentence
    }

    // MARK: - Driving

    private var controlPlayback: SkillBinding {
        SkillBinding(
            name: "control_playback",
            description: "Play, pause, skip or change the volume of whatever is playing.",
            parameters: [
                .init(
                    name: "action", type: "string",
                    description: "What to do.",
                    required: true,
                    enumValues: MediaAction.allCases.map(\.rawValue)),
                // WHICH PLAYER TO START, not which one to press. A media key
                // reaches whoever holds now-playing no matter what is named
                // here; this only decides who gets launched when nothing is
                // playing yet. See the `.play` branch below.
                .init(
                    name: "app", type: "string",
                    description: "Which player. Omit for the one that's running.",
                    required: false),
            ],
            // A TWEAK AND NOT A WRITE: instantly reversible by the same verb,
            // so it runs without confirmation. Pressing pause and being asked
            // "are you sure?" is the interaction nobody wants.
            access: .tweak,
            backing: .native { arguments, _ in
                guard let raw = arguments["action"],
                      let action = MediaAction(rawValue: raw.lowercased())
                else {
                    return SkillOutcome(
                        ok: false,
                        summary: "I don't know how to \(arguments["action"] ?? "do that") to the music.")
                }
                // NOTHING TO PRESS PLAY ON. A media key needs a process
                // holding now-playing; with no player running at all it lands
                // nowhere and the turn reports a success that made no sound.
                // Only `.play` may open one — "pause" and "next" against
                // silence are already answered correctly by doing nothing.
                if action == .play, support.resolve(arguments["app"]) == nil {
                    _ = await MediaSurfaceLaunch.resolveOrLaunch(
                        named: arguments["app"], support: support)
                }
                // WHAT THE PLAYER WAS DOING BEFORE, so the answer afterwards can
                // be about what changed rather than about what was sent. See
                // `movement(from:to:for:)`.
                let before = Self.reading(support: support, named: arguments["app"])
                // ALREADY THERE — SO DO NOT PRESS.
                //
                // PIN: THE KEY IS A TOGGLE, AND THAT MAKES A REDUNDANT REQUEST
                // THE OPPOSITE OF A NO-OP. `pause` and `play` are the same
                // hardware key; sending it to an already-paused player START S
                // the music. "Pause the music" while it is paused would begin
                // playing — the exact opposite of what was asked — and the old
                // summary then reported "Paused." over the top of it. Reading
                // the transport first is what makes an idempotent verb
                // idempotent.
                if let playing = before?.0.isPlaying {
                    if (action == .pause && !playing) || (action == .play && playing) {
                        return SkillOutcome(
                            ok: true,
                            summary: playing
                                ? "It's already playing."
                                : "It's already paused.",
                            archivePolicy: .stateSnapshot,
                            target: before?.0.element,
                            adapterTrail: ["media-surface"],
                            applicationID: before?.1.applicationID)
                    }
                }
                guard MediaTransport.post(action.key) else {
                    return SkillOutcome(
                        ok: false,
                        summary: "The media key didn't go through — check Mary's Accessibility permission.")
                }
                // PIN: a media key goes to the system, not a process we can wait on.
                let settled = await Self.settledReading(
                    support: support, named: arguments["app"])
                let landed = Self.movement(
                    from: before?.0, to: settled?.0, for: action)
                return SkillOutcome(
                    ok: true,
                    summary: Self.transportSummary(
                        action: action, before: before?.0, settled: settled, landed: landed),
                    archivePolicy: .stateSnapshot,
                    // PROVEN EFFECT ONLY. A media key that reached nothing still
                    // "succeeds": the event posts, and every window in the system
                    // may ignore it. Reading the transport either side is the only
                    // way to tell a pause that happened from a pause that was
                    // merely sent — and `landed` is the field the rest of Mary
                    // already reads for exactly that distinction.
                    landed: landed == true,
                    target: settled?.0.element,
                    adapterTrail: ["media-surface"],
                    // The player the read-back FOUND, which is the one the key
                    // actually reached — not the one the caller named.
                    applicationID: settled?.1.applicationID)
            },
            // The one thing that stops this working when everything else is
            // right — and the hint Bonnie carried that this port dropped.
            spokenFailureHint: "check Mary's Accessibility permission")
    }

    /// One read now, with no settle — the "before" half of a receipt.
    private static func reading(
        support: MediaSurfaceSupport, named: String? = nil
    ) -> (MediaSurfaceAX.Reading, MediaSurfaceRegistration)? {
        guard let (registration, pid) = support.resolve(named) ?? support.resolve(nil),
              let reading = MediaSurfaceAX.read(pid: pid, registration: registration)
        else { return nil }
        return (reading, registration)
    }

    /// Did the transport actually move? Nil means it could not be told — no
    /// declared player was readable either side, which is a different answer
    /// from "nothing moved" and must not be reported as failure.
    ///
    /// PIN: PER ACTION, because what counts as movement differs. Play and pause
    /// flip a state that can be read directly; next and previous leave the state
    /// alone and change the TITLE. Volume and mute move a system level this
    /// adapter cannot see at all through a player's transport, so they stay
    /// honestly unprovable rather than claiming a receipt they do not have.
    static func movement(
        from before: MediaSurfaceAX.Reading?,
        to after: MediaSurfaceAX.Reading?,
        for action: MediaAction
    ) -> Bool? {
        guard let before, let after else { return nil }
        switch action {
        case .play, .pause:
            guard let was = before.isPlaying, let now = after.isPlaying else { return nil }
            return was != now
        case .next, .previous:
            guard let was = before.title, let now = after.title else { return nil }
            return was != now
        case .louder, .quieter, .mute:
            return nil
        }
    }

    /// What to say about a transport key: what it did, or plainly that it could
    /// not be confirmed.
    ///
    /// PIN: "Paused." WAS A CLAIM NOBODY CHECKED. The old summary said the verb
    /// in the past tense whether a player existed, whether it was playing, and
    /// whether anything at all reacted — so a pause against silence and a pause
    /// that worked read identically. Each branch below says only what was read.
    static func transportSummary(
        action: MediaAction,
        before: MediaSurfaceAX.Reading?,
        settled: (MediaSurfaceAX.Reading, MediaSurfaceRegistration)?,
        landed: Bool?
    ) -> String {
        guard let settled else {
            // No declared player answered. The key still went to the system, and
            // something unregistered may well have taken it.
            return "Sent \(action.rawValue) — I can't see a player to confirm it."
        }
        let spoken = Self.spoken(settled.0, registration: settled.1)
        switch landed {
        case true:
            return "\(action.past) — \(spoken)"
        case false:
            // IT WAS PRESSED AND NOTHING MOVED. The "already there" cases never
            // reach here — they are answered before the key is sent — so this
            // is a real miss, and saying so beats reporting the verb.
            return "I sent \(action.rawValue), but \(settled.1.displayName) didn't move. \(spoken)"
        case nil:
            // Nothing readable either side. The key went out; whether it landed
            // is genuinely unknown, and the verb is the honest thing to report.
            return "\(action.past) — \(spoken)"
        }
    }

    /// One read after a short settle. A transport does not repaint the
    /// instant the key lands, and a read taken too early reports the state
    /// the press just changed — the most confusing possible answer.
    private static func settledReading(
        support: MediaSurfaceSupport,
        named: String? = nil
    ) async -> (MediaSurfaceAX.Reading, MediaSurfaceRegistration)? {
        try? await Task.sleep(nanoseconds: 350_000_000)
        // The named player first when one was asked for, else whoever is
        // running — a read-back that ignored the name would report the wrong
        // player's state on a machine running two.
        guard let (registration, pid) = support.resolve(named) ?? support.resolve(nil),
              let reading = MediaSurfaceAX.read(pid: pid, registration: registration)
        else { return nil }
        return (reading, registration)
    }

    public enum MediaAction: String, CaseIterable, Sendable {
        case play, pause, next, previous, louder, quieter, mute

        var key: MediaTransport.Key {
            switch self {
            // ONE KEY FOR BOTH, because the hardware has one: the system media key is a
            // TOGGLE.
            case .play, .pause: return .playPause
            case .next: return .next
            case .previous: return .previous
            case .louder: return .soundUp
            case .quieter: return .soundDown
            case .mute: return .mute
            }
        }

        var past: String {
            switch self {
            case .play: return "Playing"
            case .pause: return "Paused"
            case .next: return "Skipped ahead"
            case .previous: return "Went back"
            case .louder: return "Turned it up"
            case .quieter: return "Turned it down"
            case .mute: return "Muted"
            }
        }
    }

    // MARK: - The catalog

    private var searchCatalog: SkillBinding {
        SkillBinding(
            name: "search_music",
            description: """
                Search the Apple Music catalog for songs and report the matches \
                WITHOUT playing anything. Use for "what songs are there by …", \
                "look up …". Use play_music to actually start one.
                """,
            parameters: [
                .init(name: "query", type: "string", description: "What to look for.", required: true),
                .init(name: "artist", type: "string", description: "Artist hint.", required: false),
            ],
            access: .read,
            backing: .native { arguments, _ in
                guard let query = arguments["query"], !query.isEmpty else {
                    return SkillOutcome(ok: false, summary: "Tell me what to search for.")
                }
                do {
                    let found = try await catalog.searchSongs(query: query, limit: 10)
                    let ranked = ITunesMediaCatalogSearch.ranked(
                        query: query, artist: arguments["artist"], tracks: found)
                    guard !ranked.isEmpty else {
                        return SkillOutcome(
                            ok: true,
                            summary: "I couldn't find \"\(query)\" in the catalog.",
                            foundNothing: true)
                    }
                    return SkillOutcome(
                        ok: true,
                        summary: ranked.prefix(5)
                            .map(\.spokenDescription)
                            .joined(separator: "\n"),
                        archivePolicy: .stateSnapshot,
                        adapterTrail: ["media-surface"])
                } catch {
                    return SkillOutcome(ok: false, summary: error.localizedDescription)
                }
            })
    }

    private var playFromCatalog: SkillBinding {
        SkillBinding(
            name: "play_music",
            description: """
                Play a SONG from the Apple Music catalog — anything released, \
                whether or not the user owns it. Use for "play Stand by Me", \
                "play something by Nina Simone". NOT for one of the user's own \
                playlists; that is play_playlist.
                """,
            parameters: [
                .init(name: "query", type: "string", description: "What to play.", required: true),
                .init(name: "artist", type: "string", description: "Artist hint.", required: false),
            ],
            access: .tweak,
            backing: .native { arguments, _ in
                guard let query = arguments["query"], !query.isEmpty else {
                    return SkillOutcome(ok: false, summary: "Tell me what to play.")
                }
                do {
                    let found = try await catalog.searchSongs(query: query, limit: 10)
                    let ranked = ITunesMediaCatalogSearch.ranked(
                        query: query, artist: arguments["artist"], tracks: found)
                    guard let track = ranked.first else {
                        return SkillOutcome(
                            ok: true,
                            summary: "I couldn't find \"\(query)\" in the catalog.",
                            foundNothing: true)
                    }
                    guard NSWorkspace.shared.open(track.storeURL) else {
                        return SkillOutcome(
                            ok: false,
                            summary: "I found \(track.spokenDescription) but couldn't open it.")
                    }
                    // OPENING IS NOT PLAYING, which is the whole bug this second half
                    // fixes.
                    guard let (registration, pid) = support.resolve(nil) else {
                        return SkillOutcome(
                            ok: true,
                            summary: "Opening \(track.spokenDescription).",
                            archivePolicy: .stateSnapshot,
                            adapterTrail: ["media-surface"])
                    }
                    // The page has to arrive before its button exists.
                    try? await Task.sleep(nanoseconds: 1_400_000_000)
                    let started = await MediaSurfaceLibrary.pressPagePlay(
                        pid: pid, registration: registration)
                    let reading = MediaSurfaceAX.read(pid: pid, registration: registration)
                    return SkillOutcome(
                        ok: true,
                        summary: started
                            ? "Playing \(track.spokenDescription)."
                            : "Opened \(track.spokenDescription) — press play to start it.",
                        archivePolicy: .stateSnapshot,
                        target: reading?.element,
                        adapterTrail: ["media-surface"],
                        applicationID: registration.applicationID)
                } catch {
                    return SkillOutcome(ok: false, summary: error.localizedDescription)
                }
            })
    }

    // MARK: - The library

    private var listPlaylists: SkillBinding {
        SkillBinding(
            name: "list_playlists",
            description: """
                List ALL of the user's own playlists. Use for "what playlists \
                do I have", "show me my playlists". To check for ONE playlist \
                by name, use find_playlist instead.
                """,
            parameters: [
                .init(
                    name: "app", type: "string",
                    description: "Which player. Omit for the one that's running.",
                    required: false),
            ],
            access: .read,
            backing: .native { arguments, _ in
                guard let (registration, pid) = support.resolve(arguments["app"]) else {
                    return notRunning(arguments["app"])
                }
                let playlists = await MediaSurfaceLibrary.playlists(
                    pid: pid, registration: registration)
                guard !playlists.isEmpty else {
                    return SkillOutcome(
                        ok: true,
                        summary: "I can't see any playlists in \(registration.displayName).",
                        foundNothing: true)
                }
                return SkillOutcome(
                    ok: true,
                    summary: playlists.joined(separator: "\n"),
                    archivePolicy: .stateSnapshot,
                    adapterTrail: ["media-surface"],
                    applicationID: registration.applicationID)
            })
    }

    /// SEARCHING IS NOT LISTING, AND IT IS NOT PLAYING. `list_playlists` answers "what do I
    /// have" by reading the whole sidebar out, which is the wrong answer to "do I have a
    /// jazz playlist?".
    private var findPlaylist: SkillBinding {
        SkillBinding(
            name: "find_playlist",
            description: """
                Check whether the user has a playlist matching a name and \
                report it WITHOUT playing anything. Use for "do I have a jazz \
                playlist", "is there a playlist called Dinner Office", "find my \
                running mix".
                """,
            parameters: [
                .init(name: "query", type: "string",
                      description: "The playlist name to look for.", required: true),
                .init(
                    name: "app", type: "string",
                    description: "Which player. Omit for the one that's running.",
                    required: false),
            ],
            access: .read,
            backing: .native { arguments, _ in
                guard let wanted = arguments["query"], !wanted.isEmpty else {
                    return SkillOutcome(ok: false, summary: "Tell me which playlist to look for.")
                }
                guard let (registration, pid) = support.resolve(arguments["app"]) else {
                    return notRunning(arguments["app"])
                }
                let playlists = await MediaSurfaceLibrary.playlists(
                    pid: pid, registration: registration)
                guard !playlists.isEmpty else {
                    return SkillOutcome(
                        ok: true,
                        summary: "I can't see any playlists in \(registration.displayName).",
                        foundNothing: true)
                }
                switch SpokenTitleMatcher.resolve(wanted, in: playlists) {
                case .match(let title):
                    return SkillOutcome(
                        ok: true,
                        summary: "Yes — you have \"\(title)\".",
                        archivePolicy: .stateSnapshot,
                        adapterTrail: ["media-surface"],
                        applicationID: registration.applicationID)
                case .guessed(let title):
                    // Committed under SpokenTitleCommitContext — an
                    // interpretation, not a flat yes.
                    return SkillOutcome(
                        ok: true,
                        summary: "Probably \"\(title)\" — that's the closest match I've got.",
                        archivePolicy: .stateSnapshot,
                        adapterTrail: ["media-surface"],
                        committedGuess: true,
                        applicationID: registration.applicationID)
                case .ambiguous(let titles):
                    return SkillOutcome(
                        ok: true,
                        summary: "More than one matches: \(titles.joined(separator: ", ")).",
                        archivePolicy: .stateSnapshot,
                        adapterTrail: ["media-surface"],
                        applicationID: registration.applicationID)
                case .none(let closest):
                    return SkillOutcome(
                        ok: true,
                        summary: closest.isEmpty
                            ? "No playlist called \"\(wanted)\"."
                            : "No playlist called \"\(wanted)\". Closest: \(closest.joined(separator: ", ")).",
                        foundNothing: true)
                }
            })
    }

    private var playPlaylist: SkillBinding {
        SkillBinding(
            name: "play_playlist",
            description: """
                Play one of the user's OWN playlists, by name. Use for "play my \
                Workout playlist", "put on my running mix", "start my Dinner \
                Office playlist". NOT for a song or an album; that is play_music. \
                Use shuffle_playlist when shuffle is asked for.
                """,
            parameters: [
                .init(name: "playlist", type: "string",
                      description: "Which playlist.", required: true),
                .init(name: "app", type: "string",
                      description: "Which player. Omit for the one that's running.",
                      required: false),
            ],
            access: .tweak,
            backing: .native { arguments, _ in
                guard let wanted = arguments["playlist"], !wanted.isEmpty else {
                    return SkillOutcome(ok: false, summary: "Tell me which playlist.")
                }
                guard let (registration, pid) = await MediaSurfaceLaunch.resolveOrLaunch(
                    named: arguments["app"], support: support)
                else {
                    return notRunning(arguments["app"])
                }
                switch await MediaSurfaceLibrary.play(
                    playlistNamed: wanted, pid: pid, registration: registration
                ) {
                case .played(let name):
                    // NO POST-EFFECT AX READ. The act has already landed —
                    // an exhaustive walk here only decorates a string the
                    // confidence path discards on a clean success, and every
                    // second spent after the press is a second closer to the
                    // dispatch budget with nothing left to protect.
                    return SkillOutcome(
                        ok: true,
                        summary: "Playing \(name).",
                        archivePolicy: .stateSnapshot,
                        adapterTrail: ["media-surface"],
                        applicationID: registration.applicationID)
                case .playedAsGuess(let name):
                    // Committed under SpokenTitleCommitContext — state it as
                    // an interpretation, correctable in one word.
                    return SkillOutcome(
                        ok: true,
                        summary: "Playing \(name) — closest match to what you asked for.",
                        archivePolicy: .stateSnapshot,
                        adapterTrail: ["media-surface"],
                        committedGuess: true,
                        applicationID: registration.applicationID)
                case .ambiguous(let titles):
                    // NAMED, NEVER GUESSED — starting one of two is a coin
                    // flip, and the wrong one is audible immediately.
                    return SkillOutcome(
                        ok: true,
                        summary: "I know more than one: \(titles.joined(separator: ", ")). Which?",
                        foundNothing: true)
                case .noSuchPlaylist(let closest):
                    return SkillOutcome(
                        ok: true,
                        summary: closest.isEmpty
                            ? "I couldn't find a playlist called \"\(wanted)\"."
                            : "No playlist called \"\(wanted)\". Closest: \(closest.joined(separator: ", ")).",
                        foundNothing: true)
                case .noLibrary:
                    return SkillOutcome(
                        ok: false,
                        summary: "I can't see \(registration.displayName)'s sidebar — open it and try again.")
                case .couldNotPress:
                    return SkillOutcome(
                        ok: false,
                        summary: "I found the playlist but couldn't start it.")
                }
            })
    }

    /// SHUFFLE FIRST, THEN PLAY, and the order is load-bearing: a player applies shuffle
    /// when it builds the queue, so setting the mode after the first track has started
    /// leaves that track where it was and shuffles only what follows.
    private var shufflePlaylist: SkillBinding {
        SkillBinding(
            name: "shuffle_playlist",
            description: """
                Play one of the user's own playlists with shuffle turned ON. \
                Use for "shuffle my Workout playlist", "play my running mix on \
                shuffle". Use play_playlist when shuffle was not asked for.
                """,
            parameters: [
                .init(name: "playlist", type: "string",
                      description: "Which playlist.", required: true),
                .init(name: "app", type: "string",
                      description: "Which player. Omit for the one that's running.",
                      required: false),
            ],
            access: .tweak,
            backing: .native { arguments, _ in
                guard let wanted = arguments["playlist"], !wanted.isEmpty else {
                    return SkillOutcome(ok: false, summary: "Tell me which playlist.")
                }
                guard let (registration, pid) = await MediaSurfaceLaunch.resolveOrLaunch(
                    named: arguments["app"], support: support)
                else {
                    return notRunning(arguments["app"])
                }
                let shuffled = await MediaSurfaceLibrary.pressShuffle(
                    pid: pid, registration: registration, desired: true)
                switch await MediaSurfaceLibrary.play(
                    playlistNamed: wanted, pid: pid, registration: registration
                ) {
                case .played(let name):
                    // NO POST-EFFECT AX READ — see `playPlaylist`'s own note.
                    return SkillOutcome(
                        ok: true,
                        summary: shuffled
                            ? "Shuffling \(name)."
                            : "Playing \(name) — I couldn't reach the shuffle control.",
                        archivePolicy: .stateSnapshot,
                        adapterTrail: ["media-surface"],
                        applicationID: registration.applicationID)
                case .playedAsGuess(let name):
                    let reading = MediaSurfaceAX.read(pid: pid, registration: registration)
                    let track = reading?.title.map { " — \"\($0)\"" } ?? ""
                    return SkillOutcome(
                        ok: true,
                        summary: shuffled
                            ? "Shuffling \(name)\(track) — closest match to what you asked for."
                            : "Playing \(name)\(track) — closest match, and I couldn't reach the shuffle control.",
                        archivePolicy: .stateSnapshot,
                        adapterTrail: ["media-surface"],
                        committedGuess: true,
                        applicationID: registration.applicationID)
                case .ambiguous(let titles):
                    return SkillOutcome(
                        ok: true,
                        summary: "I know more than one: \(titles.joined(separator: ", ")). Which?",
                        foundNothing: true)
                case .noSuchPlaylist(let closest):
                    return SkillOutcome(
                        ok: true,
                        summary: closest.isEmpty
                            ? "I couldn't find a playlist called \"\(wanted)\"."
                            : "No playlist called \"\(wanted)\". Closest: \(closest.joined(separator: ", ")).",
                        foundNothing: true)
                case .noLibrary:
                    return SkillOutcome(
                        ok: false,
                        summary: "I can't see \(registration.displayName)'s sidebar — open it and try again.")
                case .couldNotPress:
                    return SkillOutcome(
                        ok: false,
                        summary: "I found the playlist but couldn't start it.")
                }
            })
    }

    // MARK: - Shared

    private func notRunning(_ requested: String?) -> SkillOutcome {
        guard let requested, !requested.isEmpty else {
            return SkillOutcome(
                ok: true,
                summary: "There's no music player running that I can see.",
                foundNothing: true)
        }
        return ClosedWorld.read(app: requested)
    }
}

extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
