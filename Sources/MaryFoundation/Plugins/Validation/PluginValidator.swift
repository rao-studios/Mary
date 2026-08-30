//
//  PluginValidator.swift
//  MaryFoundation
//
//  WHAT: Closed Plugin grammar admission. Caps and entry points.
//  IN:   AbilityPackageValidator (carried Plugin).
//  OUT:  +Validate, +Operations, +Steps, +Tokens, +ProseSurface, +CodeSurface, +Corpus.
//  PIN:  Separate from AbilityPackageValidator so the interpreter is never first notice.
//

import Foundation

/// Closed Plugin grammar. Caps live here; passes live in sibling files.
public enum PluginValidator {
    public static let maximumOperations = 128
    public static let maximumStepsPerOperation = 512
    public static let maximumCleanupStepsPerOperation = 16
    public static let maximumTotalSteps = 4_096
    public static let maximumInputsPerOperation = 32
    public static let maximumRealizations = 256
    public static let maximumTargetClasses = 32
    public static let maximumBundleNames = 8
    public static let maximumBundleNameBytes = 255
    public static let maximumSupportedReleases = 32
    public static let maximumApplicationReleaseVersionBytes = 64
    /// Menu-bar label, not a payload.
    public static let maximumMenuTitleBytes = 128
    public static let maximumTitleBytes = 96
    public static let maximumSummaryBytes = 4_096
    public static let maximumOperationSeconds: Double = 60
    public static let maximumWaitSeconds: Double = 2
    public static let maximumTextBytes = 32_768
    public static let maximumOperationAliases = 16
    public static let maximumOperationAliasBytes = 48
    public static let maximumAccessibilityIdentifierBytes = 256

}
