//
//  AwarenessSite.swift
//  MaryPlugin
//
//  WHAT: Where the user is: the application, the project, the file, the text,
//        and the caret inside it.
//  IN:   AwarenessSupport / DeclaredTextSightStore / CorpusObserver / the live surface
//  OUT:  AwarenessAdapter / AwarenessObserver
//  PIN:  ONE RESOLUTION, TWO READERS. The adapter answers the model and the
//        observer stands a brief; both have to mean the same file, or the
//        standing brief describes one thing while the read describes another.
//        Resolved from what the surface observers already published wherever
//        possible — this must not become a third poller of Accessibility.
//

import AppKit
import ApplicationServices
import Foundation
import MaryAmbient
import MaryComputerUse
import MaryFoundation

/// The work in front of the user, resolved.
public struct AwarenessSite: Sendable {
    public let registration: AwarenessRegistration
    /// The project this file belongs to, when the grammar could place it.
    public let root: String?
    /// Project-relative when there is a root, else the file's own name.
    public let relativePath: String
    public let fileName: String
    /// The document's text — live buffer when the application declares one.
    public let text: String
    /// Insertion point, in the text's own coordinates.
    public let caret: Int
    /// The user's own highlight, when one stands.
    public let highlight: Range<Int>?
    /// Whether `text` came from the live surface rather than from disk.
    public let isLive: Bool

    public init(
        registration: AwarenessRegistration,
        root: String?,
        relativePath: String,
        fileName: String,
        text: String,
        caret: Int,
        highlight: Range<Int>?,
        isLive: Bool
    ) {
        self.registration = registration
        self.root = root
        self.relativePath = relativePath
        self.fileName = fileName
        self.text = text
        self.caret = caret
        self.highlight = highlight
        self.isLive = isLive
    }

    public var corpus: PluginCorpusSchema? { registration.corpus }
}

public enum AwarenessSiteResolver {

    /// The site, or nil when nothing Mary follows is in front.
    ///
    /// `named` is the model naming an application; without one this answers
    /// the surface the observers are already standing on, which is the same
    /// rule `CodeSurfaceSupport.resolve` follows and for the same reason: an
    /// explicit question is about the work Mary is watching, not about
    /// whichever window happens to be frontmost while the user speaks.
    public static func resolve(
        named: String? = nil,
        support: AwarenessSupport = .shared,
        sight: DeclaredTextSightStore = .shared
    ) -> AwarenessSite? {
        guard let registration = registration(named: named, support: support)
        else { return nil }

        let standing = sight.current()
        let standingIsThisPlace =
            standing?.place.application == registration.applicationID
        let documentPath = standingIsThisPlace
            ? standing?.documentKey.flatMap(Self.path(fromDocumentKey:))
            : nil

        // The live buffer when the application declares one — including
        // unsaved edits, which is the whole reason a code surface exists.
        var text: String?
        var caret = 0
        var highlight: Range<Int>?
        var isLive = false
        if registration.hasCodeSurface,
           let (code, pid) = CodeSurfaceSupport.shared.resolve(registration.applicationID),
           let surface = CodeSurfaceEditorCache.frontSurface(pid: pid, registration: code),
           let live = CodeSurfaceAX.fullString(of: surface.editor) {
            text = live
            isLive = true
            if let selection = CodeSurfaceAX.selectedRange(of: surface.editor) {
                caret = selection.lowerBound
                if !selection.isEmpty { highlight = selection }
            }
        }

        // Otherwise the file the window says it is showing.
        if text == nil, let documentPath {
            text = try? String(contentsOfFile: documentPath, encoding: .utf8)
        }
        guard let resolved = text, !resolved.isEmpty else { return nil }

        let root = projectRoot(for: registration, documentPath: documentPath)
        let fileName = documentPath.map { ($0 as NSString).lastPathComponent }
            ?? standing?.documentTitle
            ?? registration.displayName
        let relativePath = root.flatMap { root in
            documentPath.map { CorpusCrawl.relativePath(of: $0, under: root) }
        } ?? fileName

        return AwarenessSite(
            registration: registration,
            root: root,
            relativePath: relativePath,
            fileName: fileName,
            text: resolved,
            caret: max(0, min(caret, resolved.count)),
            highlight: highlight.flatMap {
                $0.upperBound <= resolved.count ? $0 : nil
            },
            isLive: isLive)
    }

    /// Which followed application this is about.
    static func registration(
        named: String?, support: AwarenessSupport
    ) -> AwarenessRegistration? {
        let claims = support.all
        guard !claims.isEmpty else { return nil }
        if let named, !named.isEmpty {
            let wanted = named.lowercased()
            return claims.first {
                $0.applicationID.lowercased() == wanted
                    || $0.displayName.lowercased() == wanted
                    || $0.owns(bundleID: named)
            }
        }
        let standing = DeclaredTextSightStore.shared.current()?.place.application
            ?? CorpusObserver.shared.standingFocus?.applicationID
        guard let hit = SurfacePollTarget.pairHit(
            claims: claims, standingApplicationID: standing)
        else { return nil }
        return support.registration(applicationID: hit.applicationID)
    }

    /// The project the file sits in: what the corpus observer already settled
    /// on when it is this same application, else the declared markers climbed
    /// from the file itself.
    static func projectRoot(
        for registration: AwarenessRegistration, documentPath: String?
    ) -> String? {
        if let standing = CorpusObserver.shared.standingFocus,
           standing.applicationID == registration.applicationID {
            return standing.projectRoot
        }
        guard let documentPath, let corpus = registration.corpus,
              !corpus.projectMarkers.isEmpty
        else { return nil }
        return CorpusObserver.projectRoot(
            containing: (documentPath as NSString).deletingLastPathComponent,
            markers: corpus.projectMarkers)
    }

    /// `AXDocument` is a `file://` URL string — `CodeSurfaceWriter.fileURL`'s
    /// own measured fact, read here rather than assumed.
    static func path(fromDocumentKey key: String) -> String? {
        guard !key.isEmpty else { return nil }
        if key.hasPrefix("file://") { return URL(string: key)?.path }
        return key.hasPrefix("/") ? key : nil
    }
}
