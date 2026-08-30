//
//  MediaCatalogSearch.swift
//  MaryPlugin
//
//  THE APPLE MUSIC CATALOG, over plain HTTP — the one part of the port that
//  crossed unchanged, because it was never an Apple Event.
//
//  WHY IT SURVIVED WHEN THE REST DID NOT. The plugin this descends from drove
//  a player entirely through `tell application "Music"`, and Mary sends no
//  Apple Events; the library verbs it wrapped — playlists, ratings, library
//  search — have no road here. This one never used the scripting bridge: it
//  is the PUBLIC iTunes Search endpoint, needs no developer token, and hands
//  back a Store URL that any player registered for those links will open. So
//  the catalog half of "play me a song" works in Mary while the library half
//  waits for a lane that does not exist yet.
//
//  NOT NAMED FOR A PLAYER, and the endpoint's own vendor name is the only
//  reason that needs saying: the search is Apple's, the results are Apple's,
//  but nothing here knows or cares which application will open the URL. The
//  package names the player; this names a catalog.
//
//  THE RANKING IS THE INTERESTING PART. Apple returns relevance order, which
//  is good and not sufficient: "Stand by Me" is a complete title, not
//  title-plus-artist syntax, and a naive " by " split turns it into a search
//  for a song called "Stand" by an artist called "Me". The ladder below
//  prefers structured evidence, falls back to whole-title matches, and only
//  ever narrows — it never promotes an arbitrary first API result.
//

import Foundation
import MaryAmbient


public struct MediaCatalogTrack: Sendable, Equatable, Decodable {
    public let trackID: Int64
    public let title: String
    public let artist: String
    public let album: String
    public let storeURL: URL

    enum CodingKeys: String, CodingKey {
        case trackID = "trackId"
        case title = "trackName"
        case artist = "artistName"
        case album = "collectionName"
        case storeURL = "trackViewUrl"
    }

    public init(trackID: Int64, title: String, artist: String, album: String, storeURL: URL) {
        self.trackID = trackID
        self.title = title
        self.artist = artist
        self.album = album
        self.storeURL = storeURL
    }

    /// The Search API occasionally omits collection metadata for singles. A
    /// missing album must not discard an otherwise playable song result.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        trackID = try values.decode(Int64.self, forKey: .trackID)
        title = try values.decode(String.self, forKey: .title)
        artist = try values.decode(String.self, forKey: .artist)
        album = try values.decodeIfPresent(String.self, forKey: .album) ?? ""
        storeURL = try values.decode(URL.self, forKey: .storeURL)
    }

    public var spokenDescription: String {
        album.isEmpty ? "\(title) by \(artist)" : "\(title) by \(artist) (\(album))"
    }
}

public protocol MediaCatalogSearching: Sendable {
    func searchSongs(query: String, limit: Int) async throws -> [MediaCatalogTrack]
}

public enum MediaCatalogSearchError: LocalizedError, Equatable {
    case invalidRequest
    case serverStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "I couldn't form an Apple Music catalog search."
        case .serverStatus(let status):
            return "Apple Music catalog search returned status \(status)."
        }
    }
}

public struct ITunesMediaCatalogSearch: MediaCatalogSearching {
    public init() {}

    private struct Response: Decodable {
        var results: [MediaCatalogTrack]
    }

    static func requestURL(query: String, limit: Int, country: String? = nil) -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        var items = [
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: String(max(1, min(limit, 25)))),
            URLQueryItem(name: "explicit", value: "Yes"),
        ]
        if let country, country.count == 2 {
            items.append(URLQueryItem(name: "country", value: country.uppercased()))
        }
        components?.queryItems = items
        return components?.url
    }

    static func decode(_ data: Data) throws -> [MediaCatalogTrack] {
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        var seen = Set<Int64>()
        return decoded.results.filter { seen.insert($0.trackID).inserted }
    }

    public func searchSongs(query: String, limit: Int) async throws -> [MediaCatalogTrack] {
        let region = Locale.current.region?.identifier
        guard let url = Self.requestURL(query: query, limit: limit, country: region) else {
            throw MediaCatalogSearchError.invalidRequest
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("Mary/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw MediaCatalogSearchError.serverStatus(http.statusCode)
        }
        return try Self.decode(data)
    }

    /// Apple returns relevance order; this adds exact-title/artist preference
    /// without throwing that useful ordering away.  An explicit `artist`
    /// parameter wins, followed by a conventional "title by artist" query.
    public static func ranked(
        query: String,
        artist explicitArtist: String?,
        tracks: [MediaCatalogTrack]
    ) -> [MediaCatalogTrack] {
        let parts = parsedTerms(query: query, artist: explicitArtist)
        let explicit = explicitArtist?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requiresArtist = explicit.map { !$0.isEmpty } ?? false
        var titleTerm = parts.title
        var artistTerm = parts.artist
        var candidates = Array(tracks.enumerated())

        if !requiresArtist, artistTerm != nil {
            let fullTokens = SpokenTitleMatcher.canonicalTokens(query)
            let fullFold = PassageWidening.fold(query)
            let fullTitleMatches = candidates.filter { candidate in
                let candidateFold = PassageWidening.fold(candidate.element.title)
                let candidateTokens = SpokenTitleMatcher.canonicalTokens(candidate.element.title)
                return candidateFold == fullFold
                    || (!fullTokens.isEmpty
                        && fullTokens.allSatisfy(candidateTokens.contains))
            }
            if !fullTitleMatches.isEmpty {
                titleTerm = query
                artistTerm = nil
                candidates = fullTitleMatches
            }
        }

        if let requestedArtist = artistTerm {
            let requestedTokens = SpokenTitleMatcher.canonicalTokens(requestedArtist)
            let matchingArtist = candidates.filter { candidate in
                let candidateTokens = SpokenTitleMatcher.canonicalTokens(candidate.element.artist)
                return !requestedTokens.isEmpty
                    && requestedTokens.allSatisfy(candidateTokens.contains)
            }
            if !matchingArtist.isEmpty || requiresArtist {
                candidates = matchingArtist
            } else {
                // “Stand by Me” is a complete title, not necessarily title +
                // artist syntax. With no structured artist argument and no
                // matching artist evidence, fall back only to title matches —
                // never to an arbitrary first API result.
                titleTerm = query
                artistTerm = nil
                let fullTokens = SpokenTitleMatcher.canonicalTokens(query)
                let fullFold = PassageWidening.fold(query)
                candidates = candidates.filter { candidate in
                    let candidateFold = PassageWidening.fold(candidate.element.title)
                    let candidateTokens = SpokenTitleMatcher.canonicalTokens(candidate.element.title)
                    return candidateFold == fullFold
                        || (!fullTokens.isEmpty
                            && fullTokens.allSatisfy(candidateTokens.contains))
                }
            }
        }

        let titleFold = PassageWidening.fold(titleTerm)
        let titleTokens = SpokenTitleMatcher.canonicalTokens(titleTerm)
        let artistFold = artistTerm.map(PassageWidening.fold)
        let artistTokens = artistTerm.map(SpokenTitleMatcher.canonicalTokens) ?? []

        return candidates.sorted { lhs, rhs in
            let left = score(
                lhs.element,
                titleFold: titleFold,
                titleTokens: titleTokens,
                artistFold: artistFold,
                artistTokens: artistTokens,
                originalIndex: lhs.offset)
            let right = score(
                rhs.element,
                titleFold: titleFold,
                titleTokens: titleTokens,
                artistFold: artistFold,
                artistTokens: artistTokens,
                originalIndex: rhs.offset)
            return left > right
        }.map(\.element)
    }

    static func parsedTerms(query: String, artist explicitArtist: String?) -> (title: String, artist: String?) {
        if let explicitArtist = explicitArtist?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicitArtist.isEmpty {
            return (query, explicitArtist)
        }
        guard let range = query.range(
            of: " by ",
            options: [.backwards, .caseInsensitive, .diacriticInsensitive]
        ) else {
            return (query, nil)
        }
        let title = String(query[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = String(query[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !artist.isEmpty else { return (query, nil) }
        return (title, artist)
    }

    private static func score(
        _ track: MediaCatalogTrack,
        titleFold: String,
        titleTokens: [String],
        artistFold: String?,
        artistTokens: [String],
        originalIndex: Int
    ) -> Int {
        let candidateTitle = PassageWidening.fold(track.title)
        let candidateArtist = PassageWidening.fold(track.artist)
        let candidateTitleTokens = SpokenTitleMatcher.canonicalTokens(track.title)
        let candidateArtistTokens = SpokenTitleMatcher.canonicalTokens(track.artist)
        var result = max(0, 25 - originalIndex)

        if candidateTitle == titleFold { result += 200 }
        if !titleTokens.isEmpty,
           titleTokens.allSatisfy({ candidateTitleTokens.contains($0) }) {
            result += 80
        }
        if let artistFold {
            if candidateArtist == artistFold { result += 160 }
            if !artistTokens.isEmpty,
               artistTokens.allSatisfy({ candidateArtistTokens.contains($0) }) {
                result += 60
            }
        }
        return result
    }
}
