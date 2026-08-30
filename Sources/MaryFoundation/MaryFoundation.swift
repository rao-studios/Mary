//
//  MaryFoundation.swift
//  MaryFoundation
//
//  WHAT: Schema layer constants — package format, version, file extension.
//  IN:   AbilityPackageCodec / PluginValidator → this namespace.
//  OUT:  AXFrame, ValueEnvelope, PluginSchema, AbilityPackage (rest of this target).
//  PIN:  No AppKit/CoreGraphics/Mary* imports. Plugin = `.mary` data; adapters live in MaryPlugin.
//

import Foundation

/// Layer-wide constants. Empty enum so it cannot be instantiated.
public enum MaryFoundation {

    /// Wire format id. AbilityPackageCodec rejects a non-matching envelope first.
    public static let packageFormat = "mary.ability-package"

    /// Highest format this build will read. Higher → refuse, never partial.
    public static let packageFormatVersion = 1

    /// On-disk extension for a Plugin package.
    public static let packageFileExtension = "mary"
}
