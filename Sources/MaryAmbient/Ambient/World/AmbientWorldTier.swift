//
//  AmbientWorldTier.swift
//  Mary
//
//  Created by Ritesh Pakala Rao on 8/31/26.
//

import Foundation

public enum AmbientWorldTier: Int, Sendable, Equatable, CaseIterable, Codable {
    case hover = 1
    case activation = 2
    case selection = 3

    public var displayName: String {
        switch self {
        case .hover: return "hover"
        case .activation: return "active application"
        case .selection: return "selection"
        }
    }

    public var freshFor: TimeInterval {
        switch self {
        case .hover: return 3
        case .activation: return 15
        case .selection: return AmbientSamplingCadence.activeInterval * 2
        }
    }
}
