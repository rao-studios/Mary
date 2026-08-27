//
//  PassageRecipes+WhichPlace.swift
//

import AppKit
import Foundation

extension PassageRecipes {

    // MARK: - Which place
    /// WHICH DOCUMENT'S PLACE THIS CALL IS ABOUT. Pure, so the precedence is
    /// pinned by a table rather than discovered against a live machine.
    ///
    /// Four rungs, and the order is the argument:
    ///
    ///   1. THE HANDLE. `[S1]` carries its own place — the passage knows which
    ///      document it was cut from. This is structural knowledge and it beats
    ///      every guess below it, including a frontmost app the user happens to
    ///      have clicked into since asking.
    ///   2. AN EXPLICIT ASK. "in Xcode" is an instruction, and
    ///      `TypingTarget.resolve` already establishes that an explicit ask
    ///      wins over the frontmost app. A TAUGHT APPLICATION IS NAMEABLE HERE
    ///      BY ITS OWN ID — the same id `passageAppEnumValues` offers the
    ///      model, so an option the enum advertises is an option this rung can
    ///      actually take. It was reachable only for the compiled worlds
    ///      before, which is how `app:"scrivener"` could be a listed value that
    ///      fell through to the frontmost document.
    ///   3. FRONTMOST, through `PinnedWorld.from(bundleID:)` — the tracker's
    ///      OWN bundle-id whitelist, reused rather than re-listed. A fourth
    ///      list of three bundle ids is how the pin whitelist and the running
    ///      check drifted apart once already.
    ///   4. THE FOCUS TRACKER. Its answer survives the user alt-tabbing to
    ///      Safari to look something up mid-sentence, which is precisely when
    ///      rung 3 goes blank.
    ///
    /// Nil is a real answer and gets a real sentence — see `noWorldMessage`.
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
            if let named = AmbientWorld.from(pluginOwner: asked), named.hasEyes {
                return .lane(named)
            }
            // THE ROSTER, BELOW THE NATIVE NAMES AND ABOVE EVERY GUESS. Below,
            // because a native identity is an admission boundary rather than a
            // preference and a package may not shadow one; above frontmost,
            // because naming an application is an instruction either way.
            if let registered = AmbientApplicationIndexProvider.current
                .registration(id: asked), registered.hasEyes {
                return registered.place
            }
        }
        // THE CONTAINER THE TURN NAMED, above frontmost and below an explicit
        // ask. THE FAILURE THIS FIXES is the only genuinely destructive one on
        // this surface: coding in Xcode, saying "add this to my sourdough note",
        // and an unqualified `insert_passage` falling through to rung 3
        // (frontmost) — which targets THE SOURCE FILE.
        //
        // Safe to sit this high because `ReferenceFocus` only ever answers for
        // a container the user NAMED, in a world that is not leading, on a turn
        // with no coding cue in it. On an ordinary turn it is nil and this rung
        // does not exist. See `ReferenceFocus`'s Xcode guarantee.
        if let referent, referent.place.hasEyes { return referent.place }
        // A pin points at a place directly now. Bonnie needed a fallback
        // here — `AmbientWorld.from(pinned)` — because a pin could name a
        // compiled world; it answered the eyeless HOST lane for a taught
        // application, which would route a passage verb into the shared
        // generic lane instead of the manuscript in front of the user.
        // `PinnedWorld.from` refuses every bundle without eyes, so anything
        // reaching here is a real place and there is nothing to fall back to.
        if let pinned = PinnedWorld.from(bundleID: frontmost) {
            return pinned.place
        }
        // THE DISCIPLINE ALONE NAMES NO PLACE. Bonnie's ladder ended with a
        // switch mapping a discipline to a compiled world — coding to Xcode,
        // writing to whichever writing app was last seen. Its own comment
        // recorded why the writing arm had to be a property rather than a
        // ternary: a ternary does not fail to compile when a third writing
        // app arrives, it silently answers with the wrong one.
        //
        // With no compiled applications the mapping has nothing to map to,
        // and the honest answer is the writing place the tracker actually
        // observed — nil when nobody has written anywhere, which refuses
        // rather than guessing a document.
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

    /// NOT AN ERRAND, and this one was two of them in a row. It read "bring it
    /// up in Xcode, Pages or Scrivener and ask me again, or tell me which app
    /// it's in" — and a Skill-invoking model reads an imperative in a Skill result
    /// as a thing to go and do. That reading is traced: the live transcript
    /// shows `OPEN_IN_PAGES` firing off the back of a passage refusal, and
    /// nothing anywhere in the passage path calls it. Same repair as
    /// `PassageEditRunner.noDocumentMessage` and `PassageResolver.driftedSentence`
    /// — state the condition, delete the imperative — and pinned as a class by
    /// `PassageTests.noPassageRefusalReadsAsAnErrand` rather than one sentence
    /// at a time.
    ///
    /// THE APPS A PASSAGE VERB ACCEPTS — the watched worlds, plus every
    /// registered application that earned eyes.
    ///
    /// DERIVED, because this list was spelled four times in the tree and the
    /// fourth lives in a digest-frozen `.mary` package. Keeping the package's
    /// bytes literal and this one derived is what lets a signed schema stay
    /// signed while the roster grows; `thePassageAppListMatchesTheShippedPackage`
    /// pins that the two agree when no application is registered, so they
    /// cannot drift apart silently.
    public static var passageAppEnumValues: [String] {
        // BACKINGS, NOT EYES. An app enters this list when a passage verb can
        // actually answer for it, and the verbs resolve through
        // `backing(for:)`. `hasEyes` alone was the wrong gate: the moment a
        // package declares a perception contract it earns eyes, and gating on
        // that would put "sketch" in the model-visible enum while
        // `find_passage app:"sketch"` still fell through to the frontmost
        // world — a dead option dressed as a real one, silently targeting the
        // wrong document. Every application joins by one rule: listed because
        // RESOLVABLE — it has eyes AND a passage backing — never because it
        // is merely visible. Bonnie kept a compiled `passageBearing` list
        // beside this for the same reason and had to explain that a
        // recognized-but-unobserved world must not widen it; there is no
        // compiled list to explain away here.
        AmbientApplicationIndexProvider.current.all
            .filter { $0.hasEyes && backing(forRegistered: $0.id) != nil }
            .map(\.id)
    }

    /// A registered application's passage backing.
    ///
    /// Asked through the SAME installed resolver the natives go through, and
    /// that is the whole repair: this was a hardcoded `nil` for as long as
    /// `PassageBacking` was keyed on `AmbientWorld`, so a taught application
    /// got reads, containers, ambient facts and ceremonies — everything except
    /// the one verb that revises prose. Nil now means what it says: no
    /// backing is installed for that id, usually because its package was
    /// removed.
    static func backing(forRegistered id: String) -> PassageBacking? {
        guard let registration = AmbientApplicationIndexProvider.current
            .registration(id: id) else { return nil }
        return backing(for: registration.place)
    }

    /// The app names stay: they are the places that can hold a passage at all,
    /// and naming them is what turns "I'm not sure" into something the user can
    /// answer.
    ///
    /// GENERATED FROM THE SAME LIST THE VERBS ACCEPT, because this sentence's
    /// whole job is to tell the user what will work. A hardcoded sentence
    /// naming Xcode, Pages, Scrivener and TextEdit while Sketch was registered
    /// and editable would be Mary refusing in terms of her own stale
    /// vocabulary: the user names the app, is told it is not an option, and it
    /// would have worked.
    public static var noWorldMessage: String {
        // ITS OWN ORDER, not `watched`'s.
        //
        // The MEMBERSHIP is derived — that is the whole point, and it is what
        // stops this sentence telling a Sketch user that Sketch is not an
        // option. The ORDER must not be, because `AmbientWorld.watched` is in
        // declaration order and that order is pinned by
        // `testWorldMappingHasOneSpelling` so `PerceptionWorld.watched` lines
        // up with it positionally. That constraint exists to keep the debugger's
        // tiles in step; borrowing it here would let a change made for the
        // perception pane rewrite a sentence Mary says out loud.
        //
        // So: the coding world leads, then the writing worlds, then anything
        // registered — and alphabetically within each group. That is the
        // arbiter's own coding/writing split, it is stable under any enum
        // reordering, and it reproduces the sentence this shipped with.
        let names = passageAppEnumValues
            .compactMap { owner -> (rank: Int, name: String)? in
                if let world = AmbientWorld.from(pluginOwner: owner) {
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
    ///
    /// An enum rather than `Result`, because the failure is a SENTENCE A PERSON
    /// HEARS and not an `Error`. Wrapping it in one would invite a call site to
    /// throw it, and a thrown refusal reaches the user through
    /// `localizedDescription`, which is where carefully worded refusals go to
    /// acquire a stray "The operation couldn't be completed".
    enum Route {
        case backing(PassageBacking)
        case refused(String)
    }

    static func route(handle: String?, requested: String?) -> Route {
        // A REFUSED REFERENCE STOPS HERE, above `resolveWorld`.
        //
        // It has to be above, and that is the whole point: `resolveWorld`'s
        // referent rung reads `referent()`, which is nil on a refusal — so it
        // would decline the rung and fall straight through to rung 3,
        // FRONTMOST. That is precisely the danger the gate exists to remove
        // ("delete the Tuesday line in the other one" landing on the note in
        // front). Declining a rung and refusing a turn are opposite acts.
        //
        // An EXPLICIT `app:` still wins: the user naming the world is a
        // settled reference, and `.destroy` only refuses an UNSETTLED one.
        if case .refused(let sentence) = AmbientContextStore.shared.reference(),
           requested?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true,
           handle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            return .refused(sentence)
        }
        guard let place = resolvePlace(handle: handle, requested: requested) else {
            return .refused(noWorldMessage)
        }
        guard let found = backing(for: place) else {
            // TWO STATES SHARE THIS NIL and only one is legitimate. A world
            // genuinely without a backing gets the sentence. A NIL RESOLVER —
            // nobody ever called `installBackingResolver` — is a wiring bug:
            // this function is the dispatch path of the five passage verbs,
            // and those verbs exist only in processes that constructed
            // TyperPlugin, whose init installs the resolver. Loud in debug,
            // the same honest sentence in release.
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
