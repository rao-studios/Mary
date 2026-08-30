//
//  PassageRecipes+WhichPlace.swift
//
//  WHAT: Which writing world a passage verb aims at.
//  IN:   PassageRecipes.swift (sibling split)
//  OUT:  PassageBacking

import AppKit
import Foundation

extension PassageRecipes {

    // MARK: - Which place

    /// Which document's place this call is about. Pure — precedence is table-tested.
    /// Order: handle → explicit ask → named referent → pin → focus tracker.
    public static func resolvePlace(
        handlePlace: AmbientPlace?,
        requested: String?,
        frontmost: String?,
        focus: WorkspaceFocus?,
        writingPlace: AmbientPlace?,
        referent: ResolvedReferent? = nil
    ) -> AmbientPlace? {
        if let handlePlace, handlePlace.hasEyes { return handlePlace }
        if let requested {
            let asked = requested.trimmingCharacters(in: .whitespacesAndNewlines)
            if let named = AmbientAttention.from(pluginOwner: asked), named.hasEyes {
                return .lane(named)
            }
            // Roster: below native names, above frontmost. Naming an app is an instruction.
            if let registered = AmbientApplicationIndexProvider.current
                .registration(id: asked), registered.hasEyes {
                return registered.place
            }
        }
        // Named container for this turn: above frontmost, below an explicit ask.
        if let referent, referent.place.hasEyes { return referent.place }
        // Pin is a place with eyes. PinnedWorld.from already refuses eyeless hosts.
        if let pinned = PinnedWorld.from(bundleID: frontmost) {
            return pinned.place
        }
        // Writing place is a stored property, not a ternary — a third app would silently pick the wrong arm.
        if focus == .writing, let writingPlace { return writingPlace }
        return nil
    }

    /// The live resolution: the pure function above, fed from the process.
    public static func resolvePlace(
        handle: String?, requested: String?,
        registry: PassageRegistry = .shared,
        tracker: WorkspaceFocusTracker = .shared
    ) -> AmbientPlace? {
        var handlePlace: AmbientPlace?
        if let handle, !handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           case .live(let passage) = registry.resolve(handle) {
            handlePlace = passage.place
        }
        return resolvePlace(
            handlePlace: handlePlace,
            requested: requested,
            frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            focus: tracker.effectiveFocus(),
            writingPlace: tracker.writingPlace(),
            referent: AmbientContextStore.shared.referent())
    }

    /// NOT AN ERRAND, and this one was two of them in a row. It read "bring it up in Xcode,
    /// Pages or Scrivener and ask me again, or tell me which app it's in".
    public static var passageAppEnumValues: [String] {
        // BACKINGS, NOT EYES. An app enters this list when a passage verb can actually
        // answer for it, and the verbs resolve through `backing(for:)`.
        AmbientApplicationIndexProvider.current.all
            .filter { $0.hasEyes && backing(forRegistered: $0.id) != nil }
            .map(\.id)
    }

    /// A registered application's passage backing. Asked through the SAME installed
    /// resolver the natives go through, and that is the whole repair: this was a hardcoded
    /// `nil` for as long as `PassageBacking` was keyed on `AmbientAttention`, so a taught
    static func backing(forRegistered id: String) -> PassageBacking? {
        guard let registration = AmbientApplicationIndexProvider.current
            .registration(id: id) else { return nil }
        return backing(for: registration.place)
    }

    /// The app names stay: they are the places that can hold a passage at all, and naming
    /// them is what turns "I'm not sure" into something the user can answer.
    public static var noWorldMessage: String {
        // ITS OWN ORDER, not `watched`'s. The MEMBERSHIP is derived — that is the whole
        // point, and it is what stops this sentence telling a Sketch.
        let names = passageAppEnumValues
            .compactMap { owner -> (rank: Int, name: String)? in
                if let world = AmbientAttention.from(pluginOwner: owner) {
                    return (world.focus == .coding ? 0 : 1, world.displayName)
                }
                guard let registered = AmbientApplicationIndexProvider.current
                    .registration(id: owner)
                else { return nil }
                return (2, registered.displayName)
            }
            .sorted { ($0.rank, $0.name) < ($1.rank, $1.name) }
            .map(\.name)
        let list: String
        switch names.count {
        case 0:  list = "a document"
        case 1:  list = names[0]
        default: list = names.dropLast().joined(separator: ", ")
            + " or " + names[names.count - 1]
        }
        return "I'm not sure which document you mean. A document open in \(list) "
            + "is what I can work in, and naming the app is enough to settle it."
    }

    /// The backing for this call, or the sentence to refuse with.
    enum Route {
        case backing(PassageBacking)
        case refused(String)
    }

    static func route(handle: String?, requested: String?) -> Route {
        // A REFUSED REFERENCE STOPS HERE, above `resolveWorld`. It has to be above, and
        // that is the whole point: `resolveWorld`'s referent rung reads `referent()`, which
        // is nil on a refusal.
        if case .refused(let sentence) = AmbientContextStore.shared.reference(),
           requested?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true,
           handle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            return .refused(sentence)
        }
        guard let place = resolvePlace(handle: handle, requested: requested) else {
            return .refused(noWorldMessage)
        }
        guard let found = backing(for: place) else {
            // TWO STATES SHARE THIS NIL and only one is legitimate. A world genuinely
            // without a backing gets the sentence.
            assert(
                hasBackingResolver,
                "PassageRecipes.route dispatched with no resolver installed — "
                + "TyperPlugin/MaryAdapterCatalog must be constructed before "
                + "passage verbs dispatch.")
            return .refused(
                "I can read \(place.displayName), but I can't work with passages there yet.")
        }
        return .backing(found)
    }

}
