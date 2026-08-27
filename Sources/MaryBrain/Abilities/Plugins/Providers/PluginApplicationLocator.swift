import AppKit
import MaryFoundation
import Foundation

/// A value-only view of a running process. Keeping AppKit objects out of the
/// public result lets application discovery be injected and tested without a
/// particular application being installed on the machine running the tests.
public struct PluginRunningApplication: Hashable, Sendable {
    public var bundleIdentifier: String?
    public var localizedName: String?
    public var bundleURL: URL?
    public var shortVersion: String?
    public var bundleVersion: String?
    public var processIdentifier: Int32
    public var isTerminated: Bool

    public init(
        bundleIdentifier: String?,
        localizedName: String? = nil,
        bundleURL: URL? = nil,
        shortVersion: String? = nil,
        bundleVersion: String? = nil,
        processIdentifier: Int32,
        isTerminated: Bool = false
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
        self.bundleURL = bundleURL
        self.shortVersion = shortVersion
        self.bundleVersion = bundleVersion
        self.processIdentifier = processIdentifier
        self.isTerminated = isTerminated
    }
}

/// The current relationship between a Dynamic application declaration and
/// this Mac. Discovery is observational: an installed app is never launched.
public struct PluginApplicationResolution: Hashable, Sendable {
    public enum Status: String, Hashable, Sendable, CaseIterable {
        case running
        case ambiguous
        case installed
        case notFound
    }

    public var status: Status
    public var displayName: String
    public var matchedBundleIdentifier: String?
    public var installedURL: URL?
    public var processIdentifier: Int32?

    /// WHETHER THE RUNNING BUILD IS ONE THE PACKAGE WAS CONFORMED AGAINST —
    /// a fact reported, never a permission withheld.
    ///
    /// `supportedReleases` USED TO BE A KILL SWITCH, and it was pointed at an
    /// application that updates itself. `chrome.mary` declared exactly
    /// `151.0.7922.109`; Chrome shipped `151.0.7922.138` a few days later and
    /// every Chrome operation — including `scrollPage`, which is one key —
    /// refused before Accessibility was even asked, saying the release "is not
    /// supported by this Ability, so Mary did not acquire a foreground or
    /// input target". Nothing had actually been tried. The allowlist goes
    /// stale on a timer no user controls, so as a gate it fails closed on a
    /// schedule.
    ///
    /// It remains genuinely useful as PROVENANCE: it says what a package
    /// author verified their recipes against, which is worth showing in the
    /// Ability Explorer and Studio. So the tuple is still declared, validated,
    /// and displayed, but never affects execution decisions or outcomes. A
    /// recipe that really cannot survive a new build fails on its own step,
    /// with its own evidence, which is a truthful report rather than a guess.
    public var releaseIsVerified: Bool
    /// The build actually observed for presentation. Nil when no release
    /// metadata could be read.
    public var observedRelease: PluginApplicationReleaseSchema?

    public init(
        status: Status,
        displayName: String,
        matchedBundleIdentifier: String? = nil,
        installedURL: URL? = nil,
        processIdentifier: Int32? = nil,
        releaseIsVerified: Bool = true,
        observedRelease: PluginApplicationReleaseSchema? = nil
    ) {
        self.status = status
        self.displayName = displayName
        self.matchedBundleIdentifier = matchedBundleIdentifier
        self.installedURL = installedURL
        self.processIdentifier = processIdentifier
        self.releaseIsVerified = releaseIsVerified
        self.observedRelease = observedRelease
    }
}

/// Resolves the exact process identities declared by a Dynamic Plugin.
///
/// Every supported bundle identifier is checked for a running process before
/// LaunchServices is consulted for an installed bundle. This makes a running
/// alternate distribution authoritative over an installed-but-idle one and
/// keeps registration free of launch or activation side effects.
public struct PluginApplicationLocator: @unchecked Sendable {
    public typealias RunningApplications = @Sendable (String) -> [PluginRunningApplication]
    public typealias InstalledApplicationURL = @Sendable (String) -> URL?
    public typealias ApplicationRelease = @Sendable (
        URL
    ) -> PluginApplicationReleaseSchema?

    private let runningApplications: RunningApplications
    private let installedApplicationURL: InstalledApplicationURL
    private let applicationRelease: ApplicationRelease

    public init(
        runningApplications: @escaping RunningApplications,
        installedApplicationURL: @escaping InstalledApplicationURL,
        applicationRelease: ApplicationRelease? = nil
    ) {
        self.runningApplications = runningApplications
        self.installedApplicationURL = installedApplicationURL
        self.applicationRelease = applicationRelease ?? {
            Self.readApplicationRelease(at: $0)
        }
    }

    public static let live = PluginApplicationLocator(
        runningApplications: { bundleIdentifier in
            NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleIdentifier)
                .map {
                    let bundleURL = $0.bundleURL
                    let release = bundleURL.flatMap {
                        PluginApplicationLocator.readApplicationRelease(at: $0)
                    }
                    return PluginRunningApplication(
                        bundleIdentifier: $0.bundleIdentifier,
                        localizedName: $0.localizedName,
                        bundleURL: bundleURL,
                        shortVersion: release?.shortVersion,
                        bundleVersion: release?.bundleVersion,
                        processIdentifier: $0.processIdentifier,
                        isTerminated: $0.isTerminated)
                }
        },
        installedApplicationURL: { bundleIdentifier in
            NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleIdentifier)
        })

    @MainActor
    public func resolve(
        _ application: PluginApplicationSchema
    ) -> PluginApplicationResolution {
        // Running identity wins globally, not merely within each identifier's
        // running/installed pair. Resolve only a single exact PID: choosing one
        // of several matching processes by enumeration order would make the
        // eventual foreground and input target nondeterministic.
        var runningMatches: [(String, PluginRunningApplication)] = []
        var matchedProcessIdentifiers = Set<Int32>()
        for bundleIdentifier in application.bundleIdentifiers {
            for running in runningApplications(bundleIdentifier) where
                !running.isTerminated
                    && running.bundleIdentifier?.caseInsensitiveCompare(bundleIdentifier)
                        == .orderedSame
            {
                guard matchedProcessIdentifiers.insert(
                    running.processIdentifier).inserted
                else { continue }
                runningMatches.append((bundleIdentifier, running))
                guard runningMatches.count == 1 else {
                    return PluginApplicationResolution(
                        status: .ambiguous,
                        displayName: Self.displayName(
                            preferred: nil,
                            bundleURL: nil,
                            application: application))
                }
            }
        }

        if let (bundleIdentifier, running) = runningMatches.first {
            let observed = Self.observedRelease(
                shortVersion: running.shortVersion,
                bundleVersion: running.bundleVersion)
            return PluginApplicationResolution(
                status: .running,
                displayName: Self.displayName(
                    preferred: running.localizedName,
                    bundleURL: running.bundleURL,
                    application: application),
                matchedBundleIdentifier: bundleIdentifier,
                installedURL: running.bundleURL,
                processIdentifier: running.processIdentifier,
                releaseIsVerified: Self.releaseIsSupported(
                    shortVersion: running.shortVersion,
                    bundleVersion: running.bundleVersion,
                    by: application),
                observedRelease: observed)
        }

        // THE FIRST INSTALLED IDENTITY IN DECLARED ORDER, verified or not.
        // The loop used to SKIP an unverified build and keep looking, which
        // meant a package declaring both a stable and a beta bundle id would
        // silently prefer whichever one happened to match a stale tuple.
        // Declared order is the author's stated preference; drift is reported
        // rather than used as a tiebreak.
        for bundleIdentifier in application.bundleIdentifiers {
            guard let url = installedApplicationURL(bundleIdentifier) else { continue }
            let release = applicationRelease(url)
            let verified = application.supportedReleases.isEmpty
                || (release.map { application.supportedReleases.contains($0) } ?? false)
            return PluginApplicationResolution(
                status: .installed,
                displayName: Self.displayName(
                    preferred: nil,
                    bundleURL: url,
                    application: application),
                matchedBundleIdentifier: bundleIdentifier,
                installedURL: url,
                releaseIsVerified: verified,
                observedRelease: release)
        }

        return PluginApplicationResolution(
            status: .notFound,
            displayName: Self.displayName(
                preferred: nil,
                bundleURL: nil,
                application: application))
    }

    private static func displayName(
        preferred: String?,
        bundleURL: URL?,
        application: PluginApplicationSchema
    ) -> String {
        let candidates: [String?] = [
            preferred,
            bundleURL?.lastPathComponent,
            application.bundleNames.first,
            application.title,
            application.id,
        ]
        return candidates.lazy.compactMap(normalizedDisplayName).first
            ?? "Application"
    }

    private static func normalizedDisplayName(_ candidate: String?) -> String? {
        guard let candidate else { return nil }
        let flattened = candidate.unicodeScalars.map { scalar -> String in
            CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
        }.joined()
        var normalized = flattened.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        if normalized.lowercased().hasSuffix(".app") {
            normalized.removeLast(4)
        }
        let bounded = String(normalized.prefix(96))
        return bounded.isEmpty ? nil : bounded
    }

    /// An undeclared constraint is not an unverified build: a package that
    /// names no releases has made no claim to be wrong about.
    private static func releaseIsSupported(
        shortVersion: String?,
        bundleVersion: String?,
        by application: PluginApplicationSchema
    ) -> Bool {
        guard !application.supportedReleases.isEmpty else { return true }
        guard let shortVersion, let bundleVersion else { return false }
        return application.supportedReleases.contains(.init(
            shortVersion: shortVersion,
            bundleVersion: bundleVersion))
    }

    private static func observedRelease(
        shortVersion: String?,
        bundleVersion: String?
    ) -> PluginApplicationReleaseSchema? {
        guard let shortVersion, let bundleVersion else { return nil }
        return .init(shortVersion: shortVersion, bundleVersion: bundleVersion)
    }

    private static func readApplicationRelease(
        at bundleURL: URL
    ) -> PluginApplicationReleaseSchema? {
        guard bundleURL.isFileURL,
              let bundle = Bundle(url: bundleURL),
              let shortVersion = bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let bundleVersion = bundle.object(
                forInfoDictionaryKey: "CFBundleVersion") as? String else {
            return nil
        }
        return .init(
            shortVersion: shortVersion,
            bundleVersion: bundleVersion)
    }
}
