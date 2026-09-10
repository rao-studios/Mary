//
//  BrowserEngine+MediaClock.swift
//  MaryPlugin
//
//  WHAT: A time, as a place on the track — the player's clock from whichever
//        lane could read it, the transport's own rows in the page, and the
//        verdict a media act earns when the second look comes back.
//  IN:   MediaControlReading (pixels), PageRow (the page's own words)
//  OUT:  clock / clockRows / playerButton / volumeState / progressSlider,
//        verify / verdict — statics, no seams, no stage
//  PIN:  THE SLIDER IS A SLIDER, NOT A SITE. Everything here is a role, a range
//        or a word the page itself published; nothing knows a player by name.
//

import CoreGraphics
import Foundation
import MaryAmbient
import MaryComputerUse
import MaryFoundation

extension BrowserEngine {
    // MARK: - A time, as a place on the track

    /// The video's clock, from whichever lane could read it: the reading's own
    /// (VisionAX reads the elapsed and total times off the transport), else
    /// the page's progress slider, whose range IS the length. Nil when neither
    /// answered, which a time seek must refuse by name rather than guess.
    ///
    /// PIN: THE SLIDER IS A SLIDER, NOT A SITE. A player's progress bar is an
    /// `AXSlider` inside the picture whose maximum is the duration in seconds;
    /// that is a role and a range, published by the page, and is the same on
    /// every player that publishes one. MEASURED on the staged watch page:
    /// `slider "Progress Bar" 879×5` while playing, nothing while paused.
    static func clock(
        from media: MediaControlReading
    ) -> (elapsed: TimeInterval, duration: TimeInterval)? {
        if let duration = media.duration, duration > 0 {
            return (media.elapsed ?? 0, duration)
        }
        // ONE TIME AND A FRACTION ARE A WHOLE CLOCK. Measured in round 10: a
        // player just started shows "0:22 / 10:34" and the OCR made out only
        // the "10:34" — the elapsed sits in a highlighted box — so the reading
        // carried a lone time as the elapsed and no length, and a seek refused
        // "I can't tell how long the video is" three seconds into a video
        // whose length was on screen. A lone time at the very start of the
        // track is the length; a lone time further in, with the track's own
        // fraction, gives the length by division. The fraction is the page's
        // slider where it publishes one (`withSliderTrack`), which is what
        // makes this arithmetic and not a guess.
        guard let lone = media.elapsed, lone > 0,
              let fraction = media.progress?.fraction
        else { return nil }
        if fraction < Self.startOfTheTrack { return (0, lone) }
        return (lone, lone / fraction)
    }

    /// How far in still counts as the start, when a lone time is judged.
    static let startOfTheTrack = 0.05

    /// The page's rows near the player, read once for every fill below.
    struct PlayerSeen {
        let rows: [PageRow]
        let player: CGRect?
    }

    func seePlayer(in target: BrowserTarget, shell: WebSurfaceAX.Reading) async -> PlayerSeen? {
        guard let pageFrame = shell.pageFrame,
              case .success(let seen) = await lookOnce(
                  target, shell: shell, pageFrame: pageFrame, intent: .elements, previous: nil)
        else { return nil }
        return PlayerSeen(rows: seen.rows, player: Self.playerRegion(in: seen, page: pageFrame))
    }

    /// Whether the page's rows place the button this act needs.
    static func pagePlaces(_ action: MediaAction, in seen: PlayerSeen) -> Bool {
        let rows = seen.rows, player = seen.player
        switch action {
        case .play, .pause, .toggle:
            return playerButton(named: ["\(MediaAction.play)", "\(MediaAction.pause)"], in: rows, player: player) != nil
        case .mute, .unmute:
            return volumeState(in: rows, player: player) != nil
        case .fullscreen:
            return playerButton(named: ["full", "fullscreen"], in: rows, player: player) != nil
        case .seek, .seekTo, .seekBy:
            return progressSlider(in: rows, player: player) != nil
        case .volume:
            return false
        }
    }

    /// The reading, with what the page's own rows can add for this act.
    ///
    /// PIN: THE ROWS ARE THE WITNESS THE PIXELS COULD NOT BE. Measured, one
    /// per round: the film's first ten seconds are a pink sky that barely
    /// moves and "play" read as "still paused" at 0:05; the crossed speaker
    /// read as sound on and "mute" unmuted; the OCR made out only the length
    /// three seconds in; the centre glyph sat sixty points from the play
    /// circle in a wide window. A player's buttons are rows named for the act
    /// they would do next — a button offering to pause is a player that is
    /// playing — its slider is a row whose range is the length, and its clock
    /// is text beside the bar. Each fills only what the pixels left empty or
    /// contradicted; the pixels keep the rest.
    func fromThePage(
        _ media: MediaControlReading, for action: MediaAction, seen: PlayerSeen?
    ) -> MediaControlReading {
        guard let seen else { return media }
        var filled = media
        let rows = seen.rows, player = seen.player

        // Playback, and the play/pause button's place.
        if let button = Self.playerButton(named: ["\(MediaAction.pause)"], in: rows, player: player) {
            filled.playback = .playing
            filled.playPause = .init(frame: button.frame, glyph: .pause, confidence: 1)
        } else if let button = Self.playerButton(named: ["\(MediaAction.play)"], in: rows, player: player) {
            filled.playback = .paused
            filled.playPause = .init(frame: button.frame, glyph: .play, confidence: 1)
        }
        // The sound, and the mute button's place.
        if let state = Self.volumeState(in: rows, player: player) {
            filled.volume = .init(frame: state.frame, glyph: state.muted ? .muted : .volume, confidence: 1)
        }
        // Full screen's place, when the pixels found none.
        if filled.fullscreen == nil,
           let button = Self.playerButton(named: ["full", "fullscreen"], in: rows, player: player) {
            filled.fullscreen = .init(frame: button.frame, glyph: .fullscreen, confidence: 1)
        }
        // The clock the page publishes, before the one the pixels show.
        if let clock = Self.clockRows(in: rows, player: player) {
            if filled.elapsed == nil, let elapsed = clock.elapsed { filled.elapsed = elapsed }
            if filled.duration == nil, let duration = clock.duration { filled.duration = duration }
        }
        // The slider as the track, and its range as the length.
        if action.isTimeSeek || { if case .seek = action { return true }; return false }() {
            filled = withSliderTrack(filled, seen: seen)
        }
        if filled.playback != media.playback || filled.volume?.glyph != media.volume?.glyph {
            emit(.acted("took the page's own buttons: \(filled.playback.rawValue)"
                + (filled.isMuted.map { $0 ? ", muted" : ", sound on" } ?? "")))
        }
        return filled
    }

    /// Whether a row sits on the player or in the strip just around it — the
    /// transport's own rows, as against the page's footer wearing the same
    /// words. No player known means every row may.
    static func nearPlayer(_ frame: CGRect, _ player: CGRect?) -> Bool {
        guard let player else { return true }
        return frame.intersects(player.insetBy(dx: -8, dy: -player.height * 0.4))
    }

    /// The first pressable row near the player whose name carries one of the
    /// act's own words.
    static func playerButton(
        named words: [String], in rows: [PageRow], player: CGRect?
    ) -> PageRow? {
        return rows.first { row in
            guard row.affordance == .press, Self.nearPlayer(row.frame, player) else { return false }
            let named = row.label.lowercased().split { !$0.isLetter }.map(String.init)
            return words.contains { named.contains($0) }
        }
    }

    /// The mute button among the page's rows near the player, and what it
    /// says: a button offering to unmute is a player that is muted.
    static func volumeState(
        in rows: [PageRow], player: CGRect?
    ) -> (frame: CGRect, muted: Bool)? {
        let offersToMute = "\(MediaAction.mute)"
        let offersToUnmute = "\(MediaAction.unmute)"
        for row in rows where row.affordance == .press && Self.nearPlayer(row.frame, player) {
            let words = row.label.lowercased()
                .split { !$0.isLetter }
                .map(String.init)
            if words.contains(offersToUnmute) { return (row.frame, true) }
            if words.contains(offersToMute) { return (row.frame, false) }
        }
        return nil
    }

    /// The times the page's own rows carry near the player, left to right —
    /// the elapsed first, the length last. One lone time is handed on as the
    /// elapsed, for `clock(from:)` to judge against the track.
    static func clockRows(
        in rows: [PageRow], player: CGRect?
    ) -> (elapsed: TimeInterval?, duration: TimeInterval?)? {
        let times = rows
            .filter { Self.nearPlayer($0.frame, player) }
            .sorted { $0.frame.minX < $1.frame.minX }
            .flatMap { row in Self.times(in: row.label).map { (x: row.frame.minX, seconds: $0) } }
        guard let first = times.first else { return nil }
        if times.count == 1 { return (first.seconds, nil) }
        let longest = times.map(\.seconds).max() ?? first.seconds
        let shortest = times.map(\.seconds).min() ?? first.seconds
        return (shortest, longest)
    }

    /// Every m:ss or h:mm:ss in a label, in order.
    static func times(in label: String) -> [TimeInterval] {
        let pattern = try! NSRegularExpression(pattern: "\\b(?:(\\d{1,2}):)?(\\d{1,2}):(\\d{2})\\b")
        let text = label as NSString
        return pattern.matches(in: label, range: NSRange(location: 0, length: text.length)).map { match in
            let hours = match.range(at: 1).location == NSNotFound ? 0 : Double(text.substring(with: match.range(at: 1))) ?? 0
            let minutes = Double(text.substring(with: match.range(at: 2))) ?? 0
            let seconds = Double(text.substring(with: match.range(at: 3))) ?? 0
            return hours * 3600 + minutes * 60 + seconds
        }
    }

    /// The page's progress slider: an adjustable row inside the picture whose
    /// range is a length, wide and thin like a track. The widest range wins —
    /// a volume slider is a fraction, a progress bar is minutes.
    static func progressSlider(in rows: [PageRow], player: CGRect?) -> PageRow? {
        // ON THE PICTURE OR JUST UNDER IT. A player draws its bar over the
        // bottom of the picture or in a strip beneath it — measured, both — and
        // a bar a screen away belongs to something else.
        func belongsToThePlayer(_ frame: CGRect) -> Bool {
            guard let player else { return true }
            guard frame.maxX > player.minX, frame.minX < player.maxX else { return false }
            return frame.intersects(player)
                || (frame.minY >= player.maxY && frame.minY <= player.maxY + player.height * 0.3)
        }
        return rows
            .filter { row in
                row.affordance == .adjust
                    && (row.maximumValue ?? 0) > (row.minimumValue ?? 0)
                    && belongsToThePlayer(row.frame)
                    && row.frame.width > row.frame.height * 4
            }
            .max { ($0.maximumValue ?? 0) < ($1.maximumValue ?? 0) }
    }

    /// The reading, with whatever the page's own slider can add: a track to
    /// aim at when the picture showed none, and a length and a position when
    /// the clock was not legible. One elements read, only when something is
    /// missing.
    ///
    /// PIN: MEASURED — the picture lane finds the track on one look and loses
    /// it on the next, because a player hides its bar on a timer; the tree
    /// publishes the same bar as a slider for as long as it is drawn, with its
    /// value and range. "I can see the player but not its progress control"
    /// was said about a track that was 879 points wide in the tree.
    func withSliderTrack(
        _ media: MediaControlReading, seen: PlayerSeen?
    ) -> MediaControlReading {
        guard let seen else { return media }
        var filled = media
        let player = seen.player
        guard let slider = Self.progressSlider(in: seen.rows, player: player),
              let maximum = slider.maximumValue
        else { return Self.clocked(filled) }
        let minimum = slider.minimumValue ?? 0
        let length = maximum - minimum
        guard length > 0 else { return media }
        // THE PAGE'S RECTANGLE, OVER THE PICTURE'S. MEASURED: the pixel lane's
        // bar was a rectangle a click on which moved nothing, and reported
        // 0.6% for a video at 3:10 of 10:34; the same click on the slider the
        // tree publishes moved the video exactly. Where the position is read
        // from is decided by `clocked`; here the frame is the page's.
        let fraction = slider.value.map { min(max(($0 - minimum) / length, 0), 1) }
            ?? filled.progress?.fraction ?? 0
        filled.progress = .init(frame: slider.frame, fraction: fraction)
        emit(.acted("took the page's own slider as the track"))
        // TWO LANES AGREE ON A LENGTH, OR ONE OF THEM IS WRONG. The slider's
        // position and the clock's elapsed time give a length between them —
        // `elapsed / fraction` — that owes nothing to how the clock's digits
        // were read. MEASURED: the OCR read 10:34 as 1:40 on two runs out of
        // six; the slider stood at 0.5% with 0:03 elapsed, which is a video
        // about ten minutes long, not one. A length the clock says that is
        // off from that by more than a factor of two is the reading's, not the
        // video's; when the clock says nothing, the estimate stands alone.
        if let elapsed = filled.elapsed, slider.value != nil, fraction >= 0.002 {
            let estimated = elapsed / fraction
            if let read = filled.duration, read > 0,
               estimated / read > 2 || read / estimated > 2 {
                emit(.acted("the clock read \(SpokenDuration.clock(read)) long; the slider says about \(SpokenDuration.clock(estimated))"))
                filled.duration = estimated
            } else if filled.duration == nil {
                filled.duration = estimated
            }
        }
        if filled.duration == nil, length > 100 {
            // A range in seconds — a slider whose maximum IS the length.
            filled.duration = length
            if filled.elapsed == nil, slider.value != nil { filled.elapsed = (slider.value ?? minimum) - minimum }
        }
        return Self.clocked(filled)
    }

    /// The position, read from the clock when there is one. The transport's
    /// "3:10 of 10:34" is text the reading OCRs and is right; the bar's filled
    /// fraction is a guess about a few pixels and, measured on a thin bar, was
    /// wrong by a factor of fifty. When both exist the clock wins.
    static func clocked(_ media: MediaControlReading) -> MediaControlReading {
        guard let elapsed = media.elapsed, let duration = media.duration, duration > 0,
              var progress = media.progress
        else { return media }
        progress.fraction = min(max(elapsed / duration, 0), 1)
        var read = media
        read.progress = progress
        return read
    }

    /// A time seek as the fraction the track takes. Clamped to the video.
    static func fraction(
        for action: MediaAction, elapsed: TimeInterval, duration: TimeInterval
    ) -> Double? {
        let target: TimeInterval
        switch action {
        case .seekTo(let seconds): target = seconds
        case .seekBy(let seconds): target = elapsed + seconds
        default: return nil
        }
        guard duration > 0 else { return nil }
        return min(max(target / duration, 0), 1)
    }

    /// Did it land. Nil means it did not, and the caller refuses.
    ///
    /// PIN: MUTE HAS NO TEMPORAL WITNESS. Sound is not visible, so the only evidence is
    /// the glyph flipping — a weaker receipt than playback's, and the reason this
    /// returns a sentence naming which evidence was used rather than a bare Bool.
    /// WHAT A SECOND LOOK CAN SAY ABOUT AN ACT.
    ///
    /// PIN: "I CANNOT SEE WHETHER IT WORKED" IS NOT "IT DID NOT WORK", and
    /// collapsing the two makes Mary tell the person the stronger, wrong thing.
    /// Measured: a mute on a player whose volume glyph the reading could not make
    /// out in either look was reported as `stateUnchanged` — "I pressed it, but
    /// it's still unmuted" — about a video that had in fact gone silent. Sound is
    /// not visible; sometimes there is genuinely nothing to see, and the ranked
    /// ladder already has a rung for that: delivered, effect unverified.
    enum MediaVerdict {
        /// The second look proved it, and says how.
        case proved(String)
        /// The second look was legible and nothing moved.
        case unchanged
        /// There was nothing legible to compare — the act was delivered and its
        /// effect cannot be seen from a picture.
        case unreadable(String)
    }

    static func verdict(
        _ action: MediaAction, before: MediaControlReading, after: MediaControlReading
    ) -> MediaVerdict {
        if let proof = verify(action, before: before, after: after) {
            return .proved(proof)
        }
        switch action {
        case .mute, .unmute:
            // The glyph answered nothing in either look, so nothing was legible.
            guard after.isMuted != nil || (before.volume != nil && after.volume != nil)
            else { return .unreadable("the volume control is not legible in the picture") }
            return .unchanged
        case .fullscreen:
            guard before.bar != nil, after.bar != nil
            else { return .unreadable("the player's bar is not visible to compare") }
            return .unchanged
        case .volume:
            guard after.volumeTrack != nil
            else { return .unreadable("the volume track is not visible to compare") }
            return .unchanged
        case .seek, .seekTo, .seekBy:
            guard after.progress != nil
            else { return .unreadable("the progress track is not visible to compare") }
            return .unchanged
        case .play, .pause, .toggle:
            guard after.playback != .unknown
            else { return .unreadable("whether it is playing cannot be told from the picture") }
            return .unchanged
        }
    }

    static func verify(
        _ action: MediaAction, before: MediaControlReading, after: MediaControlReading
    ) -> String? {
        switch action {
        case .play:
            return after.playback == .playing ? "it is playing" : nil
        case .pause:
            return after.playback == .paused ? "it is paused" : nil
        case .toggle:
            guard before.playback != .unknown, after.playback != .unknown,
                  before.playback != after.playback
            else { return nil }
            return "playback flipped to \(after.playback.rawValue)"
        case .mute, .unmute:
            // MUTE HAS NO TEMPORAL WITNESS — sound is not visible — so the evidence is
            // the button itself. When the glyph is legible it answers directly; when it
            // is not, a CHANGE in what the button looks like is still evidence that the
            // press did something, and the receipt says which of the two it was rather
            // than claiming the stronger one.
            let wanted = action == .mute
            if let now = after.isMuted {
                return now == wanted ? "the volume glyph shows \(wanted ? "muted" : "sound")" : nil
            }
            guard let was = before.volume, let now = after.volume else { return nil }
            let moved = was.glyph != now.glyph
                || abs(was.confidence - now.confidence) > 0.05
            return moved ? "the volume control changed, though its shape is not legible" : nil
        case .fullscreen:
            // Vision cannot answer this: full screen replaces the whole picture, so the
            // reading after is of a different layout entirely. The honest evidence is
            // that the transport moved to the bottom of a much larger frame — or, when
            // no bar is legible either side, that the PAGE grew, which the shell reads
            // for free and which full screen changes unmistakably (measured live: the
            // frame went from the window below the toolbar to the whole window).
            if before.pageFrame.height > 0,
               after.pageFrame.height > before.pageFrame.height * 1.2 {
                return "the page filled the screen"
            }
            guard let beforeBar = before.bar, let afterBar = after.bar else { return nil }
            return afterBar.height > beforeBar.height * 1.2 ? "the player grew" : nil
        case .volume(let fraction):
            guard let now = after.volumeTrack?.fraction else { return nil }
            if abs(now - fraction) <= 0.08 { return "the volume is where it was asked for" }
            guard let was = before.volumeTrack?.fraction else { return nil }
            return abs(now - was) > 0.03 ? "the volume moved" : nil
        case .seek(let fraction):
            guard let now = after.progress?.fraction else { return nil }
            if abs(now - fraction) <= 0.05 { return "the position is where it was asked for" }
            guard let was = before.progress?.fraction else { return nil }
            return abs(now - was) > 0.02 ? "the position moved" : nil
        case .seekTo, .seekBy:
            // Never verified as such: resolved into a fraction first. See `drove`.
            return nil
        }
    }

    static func expected(_ action: MediaAction) -> String {
        switch action {
        case .play: return "playing"
        case .pause: return "paused"
        case .toggle: return "a different state"
        case .mute: return "muted"
        case .unmute: return "unmuted"
        case .fullscreen: return "full screen"
        case .seek(let fraction): return "\(Int((fraction * 100).rounded()))% through"
        case .seekTo(let seconds): return "at \(SpokenDuration.clock(seconds))"
        case .seekBy(let seconds):
            return "\(SpokenDuration.clock(seconds)) \(seconds < 0 ? "earlier" : "later")"
        case .volume(let fraction): return "the volume at \(Int((fraction * 100).rounded()))%"
        }
    }

    static func observed(_ action: MediaAction, in media: MediaControlReading) -> String {
        switch action {
        case .mute, .unmute:
            switch media.isMuted {
            case true: return "muted"
            case false: return "unmuted"
            default: return "unreadable"
            }
        case .seek:
            guard let fraction = media.progress?.fraction else { return "unreadable" }
            return "\(Int((fraction * 100).rounded()))% through"
        case .volume:
            guard let fraction = media.volumeTrack?.fraction else {
                return "a slider I can't see"
            }
            return "the volume at \(Int((fraction * 100).rounded()))%"
        case .fullscreen:
            return "the same size"
        default:
            return media.playback.rawValue
        }
    }
}

private extension MediaControlReading {
    /// The transport band, derived from what was found in it. Full screen is verified
    /// by this growing, since a fullscreen player's controls span the whole display.
    var bar: CGRect? {
        let frames = ([playPause, volume, fullscreen].compactMap { $0 }.map(\.frame))
            + (progress.map { [$0.frame] } ?? [])
        guard let first = frames.first else { return nil }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }
}
