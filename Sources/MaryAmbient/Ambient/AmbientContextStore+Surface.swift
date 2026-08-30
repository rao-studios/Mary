//
//  AmbientContextStore+Surface.swift
//  MaryBrain
//
//  WHAT: TIER 0 surface box. Every access to surfaceBox lives here.
//  IN:   observers → noteSurface
//  OUT:  prompt (AmbientSurface.surfaceLine). Sibling: AmbientContextStore
//  PIN:  Latest-wins by capture time, not receipt. Surfaces drop at expiry, never degrade.
//        No element publication — facts vectorize; a second slate would double-rank.
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
    public func surface(place: AmbientPlace, at now: Date = Date()) -> AmbientSurface? {
        surfaceBox.withLock { surfaces in
            Self.pruneSurfaces(&surfaces, at: now)
            return surfaces[place]
        }
    }

    /// Every fresh surface — place order, then newest first, so a reader
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
    public func forgetSurface(place: AmbientPlace) {
        surfaceBox.withLock { $0[place] = nil }
    }

    private static func pruneSurfaces(
        _ surfaces: inout [AmbientPlace: AmbientSurface], at now: Date
    ) {
        for (place, surface) in surfaces where !surface.isFresh(at: now) {
            surfaces[place] = nil
        }
    }
}
