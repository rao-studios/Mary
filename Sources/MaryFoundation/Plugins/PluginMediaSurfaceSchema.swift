//
//  PluginMediaSurfaceSchema.swift
//  MaryFoundation
//
//  WHERE AN APPLICATION KEEPS ITS TRANSPORT — declared, not coded.
//
//  The sibling of `PluginProseSurfaceSchema`, for the other thing an
//  application can hand Mary: not text to edit, but a player to read. Mary
//  compiles in ONE generic media adapter that knows how to find a transport
//  bar in an Accessibility tree, read what is playing, and report the state.
//  What it does NOT know is what this application calls its transport group,
//  which word its play button wears while paused, or where the position
//  slider sits. That is what a package supplies here.
//
//  WHY A DECLARATION AND NOT AN ADAPTER. The port this descends from was
//  2,285 lines of AppleScript — `tell application "Music"` for every verb,
//  including the reads. Mary sends no Apple Events at all and asks for no
//  Automation grant, so that road does not exist here. What replaced it is a
//  measured fact: a player's transport is FULLY described by its own
//  Accessibility tree. Measured against Apple Music, the Mini Player subtree
//  yields the track title as an `AXStaticText` value, the position as a
//  normalized slider value, and the three states — playing, shuffle, repeat —
//  as the LABELS of their own buttons. Nothing needed an Apple Event.
//
//  THE STATE IS IN THE LABEL, which is the load-bearing observation and the
//  reason `playingLabel` exists. A transport button does not carry a checked
//  flag; it carries the word for what pressing it would DO. A player that is
//  playing shows a button that says "Pause". So the question "is it playing?"
//  is answered by reading the label and comparing it against the word this
//  application uses — a word only the package can know, because "Pause",
//  "Suspendre" and "Pausieren" are the same button.
//
//  THE FAMILY, NOT THE APPLICATION. Everything below is true of a whole class
//  of software — "a media player that exposes its transport through
//  Accessibility" — and nothing below is true of only one member. No bundle
//  id, no product name, no per-application quirk flag. A second player joins
//  by shipping one of these, not by changing a line of Swift.
//
//  WHAT IS DELIBERATELY ABSENT. No library schema, no playlist model, no
//  rating scale. Those were Apple Events in the port and they remain out of
//  reach; a field describing them here would be a promise this build cannot
//  keep. See `multimedia.mary` for what is offered and what is deferred.
//

import Foundation

/// One Accessibility label a transport control wears, and what it means.
///
/// A PAIR AND NOT A BOOLEAN, because the label is the only evidence and both
/// halves have to be nameable. Reading only the "on" word would make every
/// unrecognized label mean "off", so a renamed control would silently report
/// a player that is never shuffling rather than a read that failed.
public struct PluginMediaToggleLabels: Codable, Hashable, Sendable {
    /// The label the control wears when the mode is ON.
    public var on: String
    /// The label it wears when the mode is OFF.
    public var off: String

    public init(on: String, off: String) {
        self.on = on
        self.off = off
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case on, off
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        on = try values.decode(String.self, forKey: .on)
        off = try values.decode(String.self, forKey: .off)
    }
}

/// The declared coordinates of one application's transport.
public struct PluginMediaSurfaceSchema: Codable, Hashable, Sendable {

    /// The Accessibility label of the group holding the transport controls.
    ///
    /// A CONTAINER AND NOT A LIST OF CONTROLS, because a player's window is
    /// full of buttons that answer to the same words — Apple Music publishes
    /// ninety-five buttons, of which eight are the transport and the rest are
    /// per-row Play buttons in the track table. Scoping to the container is
    /// what makes "the Play button" mean the one in the transport bar rather
    /// than the first of thirty in a playlist.
    public var transportLabel: String

    /// The label the play/pause button wears WHILE PLAYING — see the header.
    /// Its absence from the transport means paused or stopped.
    public var playingLabel: String

    /// The label it wears while paused, used to press play.
    public var pausedLabel: String

    /// Shuffle's two labels, when this application exposes shuffle.
    public var shuffle: PluginMediaToggleLabels?

    /// Repeat's labels. `on` matches by PREFIX, because a player commonly
    /// distinguishes modes it cannot express in two words — "repeat one" and
    /// "repeat all" are both repeat being on, and both begin with the word
    /// the package declares.
    public var repeatMode: PluginMediaToggleLabels?

    /// The label of the position slider, whose normalized value is how far
    /// through the current item the player is.
    public var positionLabel: String?

    /// What the user calls one of these — "track", "episode", "video".
    /// Mary speaks this word back rather than inventing one.
    public var itemNoun: String

    /// How often to look while this application is in use.
    public var watch: PluginProseWatchSchema

    public init(
        transportLabel: String,
        playingLabel: String,
        pausedLabel: String,
        shuffle: PluginMediaToggleLabels? = nil,
        repeatMode: PluginMediaToggleLabels? = nil,
        positionLabel: String? = nil,
        itemNoun: String = "track",
        watch: PluginProseWatchSchema = .init()
    ) {
        self.transportLabel = transportLabel
        self.playingLabel = playingLabel
        self.pausedLabel = pausedLabel
        self.shuffle = shuffle
        self.repeatMode = repeatMode
        self.positionLabel = positionLabel
        self.itemNoun = itemNoun
        self.watch = watch
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case transportLabel
        case playingLabel
        case pausedLabel
        case shuffle
        case repeatMode
        case positionLabel
        case itemNoun
        case watch
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        transportLabel = try values.decode(String.self, forKey: .transportLabel)
        playingLabel = try values.decode(String.self, forKey: .playingLabel)
        pausedLabel = try values.decode(String.self, forKey: .pausedLabel)
        shuffle = try values.decodeIfPresent(
            PluginMediaToggleLabels.self, forKey: .shuffle)
        repeatMode = try values.decodeIfPresent(
            PluginMediaToggleLabels.self, forKey: .repeatMode)
        positionLabel = try values.decodeIfPresent(String.self, forKey: .positionLabel)
        itemNoun = try values.decodeIfPresent(String.self, forKey: .itemNoun) ?? "track"
        watch = try values.decodeIfPresent(
            PluginProseWatchSchema.self, forKey: .watch) ?? .init()
    }
}
