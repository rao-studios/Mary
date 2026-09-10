//
//  DeclaredEditorRoles.swift
//  MaryPlugin
//
//  WHAT: Package-declared editor AX roles for the frontmost text surface.
//  IN:   CodeSurfaceSupport / ProseSurfaceSupport
//  OUT:  AXElementRoster / AmbientSurfaceObserver
//

import Foundation
import MaryFoundation

public enum DeclaredEditorRoles {

    /// AX role strings (`AXTextArea`, …) a declared text surface walks to.
    public static func names(bundleID: String?) -> Set<String> {
        guard let bundleID, !bundleID.isEmpty else { return [] }
        var roles = Set<String>()
        if let registration = CodeSurfaceSupport.shared.registration(bundleID: bundleID) {
            roles.formUnion(registration.editorRoleNames)
        }
        if let registration = ProseSurfaceSupport.shared.registration(bundleID: bundleID) {
            roles.formUnion(registration.editorRoleNames)
        }
        return roles
    }
}
