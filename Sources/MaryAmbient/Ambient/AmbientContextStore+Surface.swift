//
//  AmbientContextStore+Surface.swift
//  MaryBrain
//
//  TIER 0 — see `AmbientContextStore.swift`'s header for the tier doctrine.
//  Every access to `surfaceBox` lives here; the main file holds only the
//  stored box (extensions cannot hold stored properties).
//
//  LATEST-WINS BY CAPTURE TIME, not receipt — the `recordSelection`
//  ordering doctrine: a slow walk that completes late must not overwrite a
//  newer capture of the same lane.
//
//  SURFACES DROP AT EXPIRY, never degrade. A fact past freshness renders
//  with its age and loses authority — honest, because held knowledge ages.
//  A surface past freshness is a screen that may no longer exist; holding
//  it would be a confidently wrong screen waiting for a question. Pruning
//  happens on every touch, so the box stays bounded without a timer (one
//  entry per lane besides).
//
//  DELIBERATELY NO ELEMENT PUBLICATION. Facts vectorize into the element
//  index on every write (`publishElements`); the surface does not — the
//  affordance slate is the observer's own publication, scoped exactly as
//  today, and a second slate of the same screen would double-rank phrase
//  resolution.
//

import Foundation

extension AmbientContextStore {

    /// Register the tier-0 surface for its family lane.
    public func noteSurface(_ surface: AmbientSurface, at now: Date = Date()) {
        surfaceBox.withLock { surfaces in
            Self.pruneSurfaces(&surfaces, at: now)
            if let existing = surfaces[surface.place],
               existing.isFresh(at: now),
               existing.capturedAt > surface.capturedAt {
                return
            }
            surfaces[surface.place] = surface
        }
    }

    /// The fresh surface for one family lane, or nil.
    public func surface(place: AmbientRealm, at now: Date = Date()) -> AmbientSurface? {
        surfaceBox.withLock { surfaces in
            Self.pruneSurfaces(&surfaces, at: now)
            return surfaces[place]
        }
    }

    /// Every fresh surface — realm order, then newest first, so a reader
    /// without a lead in hand still gets a stable presentation.
    public func surfaces(at now: Date = Date()) -> [AmbientSurface] {
        surfaceBox.withLock { surfaces in
            Self.pruneSurfaces(&surfaces, at: now)
            return surfaces.values.sorted { lhs, rhs in
                if lhs.place.order != rhs.place.order {
                    return lhs.place.order < rhs.place.order
                }
                return lhs.capturedAt > rhs.capturedAt
            }
        }
    }

    /// Teardown for one lane — the observer's deactivate path.
    public func forgetSurface(place: AmbientRealm) {
        surfaceBox.withLock { $0[place] = nil }
    }

    private static func pruneSurfaces(
        _ surfaces: inout [AmbientRealm: AmbientSurface], at now: Date
    ) {
        for (place, surface) in surfaces where !surface.isFresh(at: now) {
            surfaces[place] = nil
        }
    }
}
