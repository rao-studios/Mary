import Foundation

/// Validation for the closed, declarative Plugin grammar. Keeping it
/// separate from the general package validator makes this admission boundary
/// independently testable and prevents the recipe interpreter from becoming
/// the first place malformed instructions are noticed.
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
    /// A menu title is a label a person reads off a menu bar, not a payload.
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
