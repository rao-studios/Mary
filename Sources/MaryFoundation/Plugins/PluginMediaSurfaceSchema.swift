//
//  PluginMediaSurfaceSchema.swift
//  MaryFoundation
//
//  WHAT: Transport-bar coordinates for a generic media adapter (AX, not Apple Events).
//  IN:   PluginSchema.mediaSurface.
//  OUT:  media adapter; PluginValidator+Validate (eyes).
//  PIN:  Playing state is in the button label (`playingLabel`).
//

import Foundation

/// On/off labels for one control. Pair, not boolean — unknown label is a failed read.
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

    /// Transport group label. Scopes Play to the bar, not per-row buttons.
    public var transportLabel: String

    /// Skip-forward label. Finds transport when the group is unlabeled; Play+Next, not Play alone.
    public var nextLabel: String?

    /// Playing-state label. Absence from transport means paused/stopped.
    public var playingLabel: String

    /// The label it wears while paused, used to press play.
    public var pausedLabel: String

    /// Shuffle's two labels, when this application exposes shuffle.
    public var shuffle: PluginMediaToggleLabels?

    /// Repeat labels. `on` matches by prefix (repeat one / repeat all).
    public var repeatMode: PluginMediaToggleLabels?

    /// Position slider label. Value is normalized progress.
    public var positionLabel: String?

    /// Page Play — starts what's on screen. Not transport `pausedLabel`.
    public var pagePlayLabel: String?

    /// Outline holding library and playlists.
    public var libraryLabel: String?

    /// Pressed only when library is missing. Reveals the library view.
    public var libraryRevealLabel: String?

    /// Header after which the outline lists playlists. Not a container.
    public var playlistSectionLabel: String?

    /// Navigation rows in that section to skip (not playlists).
    public var playlistSectionSkips: [String]

    /// Spoken noun (`track`, `episode`).
    public var itemNoun: String

    /// How often to look while this application is in use.
    public var watch: PluginProseWatchSchema

    public init(
        transportLabel: String,
        playingLabel: String,
        pausedLabel: String,
        nextLabel: String? = nil,
        shuffle: PluginMediaToggleLabels? = nil,
        repeatMode: PluginMediaToggleLabels? = nil,
        positionLabel: String? = nil,
        pagePlayLabel: String? = nil,
        libraryLabel: String? = nil,
        libraryRevealLabel: String? = nil,
        playlistSectionLabel: String? = nil,
        playlistSectionSkips: [String] = [],
        itemNoun: String = "track",
        watch: PluginProseWatchSchema = .init()
    ) {
        self.transportLabel = transportLabel
        self.playingLabel = playingLabel
        self.pausedLabel = pausedLabel
        self.nextLabel = nextLabel
        self.shuffle = shuffle
        self.repeatMode = repeatMode
        self.positionLabel = positionLabel
        self.pagePlayLabel = pagePlayLabel
        self.libraryLabel = libraryLabel
        self.libraryRevealLabel = libraryRevealLabel
        self.playlistSectionLabel = playlistSectionLabel
        self.playlistSectionSkips = playlistSectionSkips
        self.itemNoun = itemNoun
        self.watch = watch
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case transportLabel
        case playingLabel
        case pausedLabel
        case nextLabel
        case shuffle
        case repeatMode
        case positionLabel
        case pagePlayLabel
        case libraryLabel
        case libraryRevealLabel
        case playlistSectionLabel
        case playlistSectionSkips
        case itemNoun
        case watch
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        transportLabel = try values.decode(String.self, forKey: .transportLabel)
        playingLabel = try values.decode(String.self, forKey: .playingLabel)
        pausedLabel = try values.decode(String.self, forKey: .pausedLabel)
        nextLabel = try values.decodeIfPresent(String.self, forKey: .nextLabel)
        shuffle = try values.decodeIfPresent(
            PluginMediaToggleLabels.self, forKey: .shuffle)
        repeatMode = try values.decodeIfPresent(
            PluginMediaToggleLabels.self, forKey: .repeatMode)
        positionLabel = try values.decodeIfPresent(String.self, forKey: .positionLabel)
        pagePlayLabel = try values.decodeIfPresent(String.self, forKey: .pagePlayLabel)
        libraryLabel = try values.decodeIfPresent(String.self, forKey: .libraryLabel)
        libraryRevealLabel = try values.decodeIfPresent(
            String.self, forKey: .libraryRevealLabel)
        playlistSectionLabel = try values.decodeIfPresent(
            String.self, forKey: .playlistSectionLabel)
        playlistSectionSkips = try values.decodeIfPresent(
            [String].self, forKey: .playlistSectionSkips) ?? []
        itemNoun = try values.decodeIfPresent(String.self, forKey: .itemNoun) ?? "track"
        watch = try values.decodeIfPresent(
            PluginProseWatchSchema.self, forKey: .watch) ?? .init()
    }
}
