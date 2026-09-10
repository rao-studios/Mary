//
//  RuntimePrimitiveOperations.swift
//  MaryFoundation
//
//  WHAT: Host-only operations packages cannot claim or compose.
//  IN:   AbilityPackageValidator / runtime compatibility join.
//  OUT:  AbilityRuntime dispatch gate.
//

/// Closed host vocabulary. Same set for admission and runtime.
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
