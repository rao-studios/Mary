/// Mary-owned runtime operations that may be exposed directly by the host,
/// but can never be claimed, rebound, or composed by an imported Ability
/// package. Keeping the vocabulary in MaryFoundation lets admission and the
/// runtime compatibility join enforce the same closed boundary.
public enum RuntimePrimitiveOperations {
    public static let names: Set<String> = [
        "run_applescript",
        "run_shell",
        "confirm_pending_skill",
        "cancel_pending_skill",
    ]

    public static func contains(_ operation: String) -> Bool {
        names.contains(operation)
    }
}
