//
//  MediaSurfaceAdapter.swift
//  MaryPlugin
//
//  THE SKILLS A DECLARED PLAYER CAN ANSWER — say what is playing, drive the
//  transport, find a song in the catalog.
//
//  WHY THESE ARE HERE AND NOT IN A PACKAGE, the same two reasons the prose
//  adapter gives. A managed-UI recipe presses keys and reports whether the
//  press landed; it has no channel for handing a value back, so `now_playing`
//  — whose whole purpose is a value — must bind to a compiled provider. And a
//  media key is not a chord: it is an `NSSystemDefined` event the recipe
//  grammar cannot express at all, so `control_playback` needs one too.
//
//  NO PLAYER IS NAMED. Every Skill takes an optional `app`; the registration
//  behind it decides everything else — which window to read, what its
//  transport group is called, which word its button wears while playing.
//
//  WHAT THE PORT LEFT BEHIND, and what turned out not to be left behind at
//  all. Bonnie's plugin offered `play_playlist`, `play_song_in_playlist`,
//  `list_playlists`, library `search_music` and `rate_track`, all of them
//  Apple Events against Music's scripting dictionary — and Mary has no Apple
//  Events lane and asks for no Automation grant. The whole group was written
//  off on that basis, WHICH WAS THE WRONG INFERENCE for most of it: an Apple
//  Event was the road Bonnie took, not the destination. The sidebar is an
//  ordinary `AXOutline`, so `list_playlists`, `play_playlist`,
//  `find_playlist` and `shuffle_playlist` are all here and all reached
//  through Accessibility (see `MediaSurfaceLibrary`).
//
//  STILL GENUINELY OUT: `rate_track` and library-scoped `search_music`, which
//  read and write catalog metadata rather than press anything on screen.
//  Those really do want a lane this build does not have.
//

import AppKit
import Foundation
import MaryAmbient
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

    /// THE TYPED HANDSHAKE, declared rather than defaulted.
    ///
    /// THE FAILURE THIS FIXES: the protocol's default manifest publishes an
    /// operation's NAME and nothing else — no capabilities, no Value types, no
    /// target classes. Every Capability in `multimedia.mary` that reads or
    /// drives a player constrains itself with `allowedTargetClass:
    /// media-player`, and `InstalledAdapterInventory` refuses a binding whose
    /// operation does not IMPLEMENT one of the allowed classes. An operation
    /// claiming no class implements none, so `control_playback`, `now_playing`,
    /// `list_playlists` and `play_playlist` were all published, all installed,
    /// and all unavailable:
    ///
    ///     control_playback is unavailable: Operation control_playback does not
    ///     implement an allowed target class: media-player.
    ///
    /// AND IT LOOKED SELECTIVE, which is what made it puzzling rather than
    /// obvious: `search_music` and `play_music` stayed READY throughout,
    /// because `catalog.search` and `catalog.open` constrain no target class,
    /// so the check never ran for them. Two Skills working is a far better
    /// disguise for a missing declaration than none working.
    ///
    /// `providesPerceptions` is the same omission one level up. Every
    /// multimedia Skill requires `perception.player-transport`, the package
    /// declares it, and NOTHING published it — which is what
    /// `multimedia.open-player` was reporting from behind its own package
    /// adapter. Reading a player's transport is precisely what this adapter
    /// does; saying so is what makes the Skills that need it eligible.
    ///
    /// STILL `.incremental`, deliberately. An empty list here keeps meaning
    /// "not specified" rather than "supports none", which is what lets
    /// `search_music` — which queries a web endpoint and touches no player —
    /// leave its target class and observed Perception blank without being
    /// refused for it. This adapter earns `.complete` when the lanes its
    /// header describes as missing actually land.
    public var adapterManifest: InstalledAdapterManifest {
        let adapterID = AdapterID.normalized(name)
        func operation(
            _ name: String,
            capability: CapabilityID,
            input: ValueTypeID,
            output: ValueTypeID,
            // MEDIA-PLAYER OR NOTHING, per operation rather than adapter-wide:
            // the two catalog operations reach the iTunes Search endpoint and
            // target no application at all, and claiming a class they do not
            // drive would be the same untruth in the opposite direction.
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
            // WHAT THE MACHINE ACTUALLY GRANTED is not this adapter's to
            // decide; these name the two boundaries its operations cross, and
            // the Capability schemas requiring them are checked against this
            // list. Accessibility reads the transport and the sidebar; the
            // network reaches the public iTunes Search endpoint.
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
                    // NOTHING PLAYING IS A MISS, not a failure. The read
                    // worked; there is simply no answer to give, and a turn
                    // that says so is more useful than one that reports an
                    // error against a player sitting quietly.
                    foundNothing: reading.title == nil && reading.isPlaying != true,
                    target: reading.element,
                    adapterTrail: ["media-surface"])
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
        // PARENTHESES, NOT A DASH, and the reason is the data: the subtitle
        // is already dash-joined by the player ("Enfant Sauvage — Petrichor"),
        // so appending it with another dash produced a sentence with three of
        // them in a row and no way to tell which one separated what.
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
                guard MediaTransport.post(action.key) else {
                    return SkillOutcome(
                        ok: false,
                        summary: "The media key didn't go through — check Mary's Accessibility permission.")
                }
                // THE READ-BACK IS BEST EFFORT, and deliberately does not
                // gate the outcome. A media key goes to the system, not to a
                // process we can wait on; reporting failure because no
                // declared player was running would call a successful pause
                // of a browser video a failure.
                let settled = await Self.settledReading(support: support)
                return SkillOutcome(
                    ok: true,
                    summary: settled.map { reading, registration in
                        "\(action.past) — \(Self.spoken(reading, registration: registration))"
                    } ?? action.past + ".",
                    archivePolicy: .stateSnapshot,
                    target: settled?.0.element,
                    adapterTrail: ["media-surface"])
            })
    }

    /// One read after a short settle. A transport does not repaint the
    /// instant the key lands, and a read taken too early reports the state
    /// the press just changed — the most confusing possible answer.
    private static func settledReading(
        support: MediaSurfaceSupport
    ) async -> (MediaSurfaceAX.Reading, MediaSurfaceRegistration)? {
        try? await Task.sleep(nanoseconds: 350_000_000)
        guard let (registration, pid) = support.resolve(nil),
              let reading = MediaSurfaceAX.read(pid: pid, registration: registration)
        else { return nil }
        return (reading, registration)
    }

    public enum MediaAction: String, CaseIterable, Sendable {
        case play, pause, next, previous, louder, quieter, mute

        var key: MediaTransport.Key {
            switch self {
            // ONE KEY FOR BOTH, because the hardware has one: the system
            // media key is a TOGGLE. Mary offers the two words a person
            // actually says and sends the same event for each — the
            // alternative is refusing "play" while paused, which is absurd.
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
                    // OPENING IS NOT PLAYING, which is the whole bug this
                    // second half fixes. A Store URL navigates the player to
                    // the track's page and leaves it there; the first version
                    // reported success at exactly that point, and the song sat
                    // on screen in silence. The page's own play control is
                    // what starts it — never the transport's, which would
                    // resume whatever was queued before and play the wrong
                    // thing convincingly.
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
                        adapterTrail: ["media-surface"])
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
                    adapterTrail: ["media-surface"])
            })
    }

    /// SEARCHING IS NOT LISTING, AND IT IS NOT PLAYING. `list_playlists`
    /// answers "what do I have" by reading the whole sidebar out, which is the
    /// wrong answer to "do I have a jazz playlist?" — and `play_playlist`
    /// answers it by starting one, which is worse, because the question was
    /// not a request for music. This is the read that sits between them: the
    /// same fuzzy ladder `play_playlist` resolves a spoken name with, stopping
    /// one step short of pressing anything.
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
                        adapterTrail: ["media-surface"])
                case .ambiguous(let titles):
                    return SkillOutcome(
                        ok: true,
                        summary: "More than one matches: \(titles.joined(separator: ", ")).",
                        archivePolicy: .stateSnapshot,
                        adapterTrail: ["media-surface"])
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
                guard let (registration, pid) = support.resolve(arguments["app"]) else {
                    return notRunning(arguments["app"])
                }
                switch await MediaSurfaceLibrary.play(
                    playlistNamed: wanted, pid: pid, registration: registration
                ) {
                case .played(let name):
                    let reading = MediaSurfaceAX.read(pid: pid, registration: registration)
                    return SkillOutcome(
                        ok: true,
                        summary: reading?.title.map { "Playing \(name) — \"\($0)\"." }
                            ?? "Playing \(name).",
                        archivePolicy: .stateSnapshot,
                        target: reading?.element,
                        adapterTrail: ["media-surface"])
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

    /// SHUFFLE FIRST, THEN PLAY, and the order is load-bearing: a player
    /// applies shuffle when it builds the queue, so setting the mode after the
    /// first track has started leaves that track where it was and shuffles
    /// only what follows — which sounds like the mode was ignored.
    ///
    /// THE MODE IS NOT THE POINT OF THE TURN. A shuffle that could not be set
    /// is reported alongside the music rather than instead of it: the user
    /// asked to hear a playlist, and refusing to play it because a toggle went
    /// unread would be answering a smaller question than the one asked.
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
                guard let (registration, pid) = support.resolve(arguments["app"]) else {
                    return notRunning(arguments["app"])
                }
                let shuffled = await MediaSurfaceLibrary.pressShuffle(
                    pid: pid, registration: registration, desired: true)
                switch await MediaSurfaceLibrary.play(
                    playlistNamed: wanted, pid: pid, registration: registration
                ) {
                case .played(let name):
                    let reading = MediaSurfaceAX.read(pid: pid, registration: registration)
                    let track = reading?.title.map { " — \"\($0)\"" } ?? ""
                    return SkillOutcome(
                        ok: true,
                        summary: shuffled
                            ? "Shuffling \(name)\(track)."
                            : "Playing \(name)\(track) — I couldn't reach the shuffle control.",
                        archivePolicy: .stateSnapshot,
                        target: reading?.element,
                        adapterTrail: ["media-surface"])
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
