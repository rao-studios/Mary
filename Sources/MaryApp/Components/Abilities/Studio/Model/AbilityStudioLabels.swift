//
//  AbilityStudioLabels.swift
//  Mary
//
//  WHAT: Plain words for schema values the Studio shows.
//  IN:   Studio header, rail, panes, drawer.
//  OUT:  AbilityParadigmPresentation / AbilityRealizationPresentation vocabulary.
//  PIN:  Free functions, not view extensions — the old ones hung off the browser
//        view and died with it.
//

import MaryBrain
import SwiftUI

enum AbilityStudioLabels {

    // MARK: - Role

    /// "Apple Music expertise · extends Multimedia". The header's menu label.
    static func role(_ package: MaryAbilityPackage) -> String {
        AbilityParadigmPresentation(package.paradigm).detailLabel(
            applications: package.applicationAffinities,
            extending: package.extendedDisciplines.map(\.rawValue))
    }

    static func roleSymbol(_ package: MaryAbilityPackage) -> String {
        AbilityParadigmPresentation(package.paradigm).symbol
    }

    // MARK: - Provenance

    /// A package saved into `Abilities/Overrides` shadows an immutable base one.
    static func isLocalOverride(_ record: AbilityPackageRecord) -> Bool {
        record.source == .installed
            && record.sourceURL.deletingLastPathComponent().lastPathComponent == "Overrides"
    }

    static func provenance(_ record: AbilityPackageRecord) -> String {
        isLocalOverride(record) ? "Local override" : record.trustStatus.label
    }

    static func provenanceDetail(_ record: AbilityPackageRecord) -> String {
        isLocalOverride(record)
            ? "Saved locally in Application Support. It overrides the immutable base package without changing it."
            : record.trustStatus.detail
    }

    static func trustSymbol(_ status: AbilityPackageTrustStatus) -> String {
        switch status {
        case .bundled: return "checkmark.shield.fill"
        case .developmentSource: return "hammer.fill"
        case .installedSigned: return "signature"
        case .installedUnsigned: return "exclamationmark.shield"
        }
    }

    // MARK: - Skills

    static func kindSymbol(_ kind: SkillKind) -> String {
        switch kind {
        case .cognitive: return "brain"
        case .effectful: return "hand.point.up.left.fill"
        case .workflow: return "point.3.filled.connected.trianglepath.dotted"
        }
    }

    static func kindWord(_ kind: SkillKind) -> String {
        switch kind {
        case .cognitive: return "asks the model"
        case .effectful: return "acts"
        case .workflow: return "a recipe"
        }
    }

    /// Access as a promise to the user, not as a schema token.
    static func accessWord(_ access: SkillAccess) -> String {
        switch access {
        case .seamless: return "runs unasked"
        case .reversible: return "runs unasked, can be undone"
        case .confirm: return "asks first"
        }
    }

    static func accessSymbol(_ access: SkillAccess) -> String? {
        switch access {
        case .seamless: return nil
        case .reversible: return "arrow.uturn.backward"
        case .confirm: return "hand.raised.fill"
        }
    }

    static func readinessColor(_ readiness: SkillReadiness) -> Color {
        switch readiness {
        case .ready: return .maryGreen
        case .partial: return .maryGold
        case .blocked: return Paper.graphite
        }
    }

    static func readinessWord(_ readiness: SkillReadiness) -> String {
        switch readiness {
        case .ready: return "ready"
        case .partial: return "partly ready"
        case .blocked: return "cannot run"
        }
    }

    // MARK: - Application

    static func activation(_ activation: PluginApplicationActivation) -> String {
        switch activation {
        case .activateRunning: return "Bring forward if already running"
        case .requireFrontmost: return "Require the app to be frontmost"
        }
    }

    static func applicationStatus(_ status: PluginApplicationResolution.Status) -> String {
        switch status {
        case .running: return "Running"
        case .ambiguous: return "Ambiguous"
        case .installed: return "Installed, not running"
        case .notFound: return "Not found"
        }
    }

    static func applicationStatusColor(_ status: PluginApplicationResolution.Status) -> Color {
        switch status {
        case .running: return .maryGreen
        case .ambiguous: return .maryError
        case .installed: return .maryGold
        case .notFound: return Paper.graphite
        }
    }

    static func permission(_ permission: PermissionKind) -> String {
        switch permission {
        case .screenRecording: return "Screen Recording"
        case .speechRecognition: return "Speech Recognition"
        default:
            return permission.rawValue.prefix(1).uppercased()
                + permission.rawValue.dropFirst()
        }
    }

    // MARK: - Realization

    static func providerWord(_ providerClass: PluginProviderClass) -> String {
        AbilityRealizationPresentation(providerClass).label
    }

    static func providerSymbol(_ providerClass: PluginProviderClass) -> String {
        AbilityRealizationPresentation(providerClass).symbol
    }
}
