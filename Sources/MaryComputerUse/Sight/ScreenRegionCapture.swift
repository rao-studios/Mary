//
//  ScreenRegionCapture.swift
//  MaryComputerUse
//
//  WHAT: One ephemeral pixel read of the attended region.
//  IN:   AX focus / web / window  OUT: in-memory JPEG
//  PIN:  Ambient perception is AX only. Screen Recording: minimap,
//        take_screenshot, and this look — never watchers.

import AppKit
import ApplicationServices
import Foundation
import MaryAmbient
import ScreenCaptureKit

public enum ScreenRegionCapture {

    // MARK: - Public surface

    /// Where the chosen region came from, most precise first. The label is
    /// spoken back to the user so a whole-window fallback is never disguised
    /// as precision.
    public enum RegionProvenance: String, Sendable {
        case declaredEditor
        case elementUnderCursor
        case webContent
        case windowContent
        case wholeWindow

        public var spokenLabel: String {
            switch self {
            case .declaredEditor: return "the editor in front of you"
            case .elementUnderCursor: return "the region under your cursor"
            case .webContent: return "the page content"
            case .windowContent: return "the window's content"
            case .wholeWindow: return "the whole window"
            }
        }
    }

    public struct View: Sendable {
        /// The frontmost application's name ("Safari", "Preview", "Slack").
        public let appTitle: String
        /// The frontmost application's bundle identifier — STRUCTURAL, not prose.
        public let bundleID: String?
        /// The focused window's title — usually the page or document title.
        public let windowTitle: String?
        /// The captured region in global top-left screen points.
        public let contentRect: CGRect
        public let provenance: RegionProvenance
        /// Compressed image bytes — in memory only, never written anywhere.
        public let imageData: Data
        /// Always "image/jpeg" (screenshots of photos and video frames
        /// compress an order of magnitude better than PNG).
        public let mediaType: String
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case nothingFrontmost
        case accessibilityDenied
        case windowUnavailable
        case screenRecordingUnavailable(String)

        public var errorDescription: String? {
            switch self {
            case .nothingFrontmost:
                return "Nothing is frontmost to look at."
            case .accessibilityDenied:
                return "Mary needs Accessibility permission to find what you're looking at."
            case .windowUnavailable:
                return "The frontmost application has no readable focused window."
            case .screenRecordingUnavailable(let reason):
                return "Mary needs Screen Recording permission to see the screen: \(reason)"
            }
        }
    }

    public static func captureFocusRegion(hint phrase: String?) async throws -> View {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            ComputerUseMonitor.shared.note(
                lane: .sight, refused: "capture",
                reason: .other("nothing is frontmost"))
            throw Failure.nothingFrontmost
        }
        guard AXIsProcessTrusted() else {
            ComputerUseMonitor.shared.note(lane: .sight, refused: "capture", reason: .accessibilityUntrusted)
            throw Failure.accessibilityDenied
        }
        let appTitle = frontmost.localizedName
            ?? frontmost.bundleIdentifier
            ?? "an unknown application"

        let application = AXUIElementCreateApplication(frontmost.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.5)
        // Best-effort web-area discovery lives in this file's own BFS (`webAreaFrame`).
        guard let window = element(application, kAXFocusedWindowAttribute as String)
                ?? element(application, kAXMainWindowAttribute as String),
              let windowRect = frame(of: window) else {
            throw Failure.windowUnavailable
        }
        let windowTitle = string(window, kAXTitleAttribute as String)

        // Declared editor pane outranks cursor/split/window when a tag is standing.
        if let pane = WorkspaceFocusTracker.shared.signal().lookTarget,
           pane.frame.width > 0, pane.frame.height > 0,
           pane.frame.intersects(windowRect) {
            let region = pane.frame.intersection(windowRect)
            let imageData = try await captureCompressed(
                windowID: windowID(of: window),
                processIdentifier: frontmost.processIdentifier,
                windowRect: windowRect,
                contentRect: region)
            ComputerUseMonitor.shared.note(
                lane: .sight, act: "capture", pid: frontmost.processIdentifier,
                detail: "declaredEditor \(Int(region.width))×\(Int(region.height)) "
                    + "\(imageData.count) bytes")
            return View(
                appTitle: appTitle,
                bundleID: frontmost.bundleIdentifier,
                windowTitle: windowTitle,
                contentRect: region,
                provenance: .declaredEditor,
                imageData: imageData,
                mediaType: "image/jpeg")
        }

        // Region estimation is best-effort on top of an honest floor: any
        // AX hiccup below degrades toward the whole window, never a throw.
        let cursor = CGEvent(source: nil)?.location ?? .zero
        let hint = RegionHint(phrase: phrase)
        var candidates = ancestorCandidates(
            at: cursor, in: window, processIdentifier: frontmost.processIdentifier)
        let webArea = webAreaFrame(in: window)
        if let hint, hint != .text {
            candidates.append(contentsOf: hintedDescendants(
                matching: hint,
                from: candidates.first.map { _ in window } ?? window))
        }
        let (region, provenance) = chooseRegion(
            cursor: cursor,
            window: windowRect,
            ancestors: candidates,
            webArea: webArea,
            contentChildren: contentChildCandidates(of: window),
            hint: hint)

        let imageData = try await captureCompressed(
            windowID: windowID(of: window),
            processIdentifier: frontmost.processIdentifier,
            windowRect: windowRect,
            contentRect: region)
        ComputerUseMonitor.shared.note(
            lane: .sight, act: "capture", pid: frontmost.processIdentifier,
            detail: "\(provenance) \(Int(region.width))×\(Int(region.height)) "
                + "\(imageData.count) bytes")
        return View(
            appTitle: appTitle,
            bundleID: frontmost.bundleIdentifier,
            windowTitle: windowTitle,
            contentRect: region,
            provenance: provenance,
            imageData: imageData,
            mediaType: "image/jpeg")
    }

    // MARK: - Region choice (pure, headless-testable)

    /// A candidate region: an AX element reduced to what the chooser needs.
    struct Candidate: Equatable {
        var role: String
        var subrole: String?
        var description: String?
        var frame: CGRect
    }

    /// What the user's phrase says they mean, when it says anything.
    enum RegionHint: Equatable {
        case image
        case video
        case text

        init?(phrase: String?) {
            guard let phrase = phrase?.lowercased(), !phrase.isEmpty else { return nil }
            let words = phrase.split(whereSeparator: { !$0.isLetter }).map(String.init)
            if !Set(words).isDisjoint(with: ["image", "photo", "picture", "screenshot", "diagram", "chart", "graphic"]) {
                self = .image
            } else if !Set(words).isDisjoint(with: ["video", "player", "movie", "clip", "trailer"]) {
                self = .video
            } else if !Set(words).isDisjoint(with: ["text", "paragraph", "article", "sentence", "caption"]) {
                self = .text
            } else {
                return nil
            }
        }
    }

    /// Container roles that plausibly bound "the thing the user means" —
    /// preferred, but any sufficiently sized ancestor qualifies, because
    /// arbitrary applications name roles unpredictably.
    static let preferredContainerRoles: Set<String> = [
        "AXImage", "AXWebArea", "AXScrollArea", "AXGroup",
        "AXLayoutArea", "AXSplitGroup", "AXCell", "AXList",
    ]

    /// A region smaller than this is never the subject (a button, an icon).
    static let minimumRegionSize = CGSize(width: 320, height: 240)
    /// A region larger than this share of the window is just the window.
    static let maximumWindowShare: CGFloat = 0.85
    /// Breathing room added around a chosen element, clipped to the window.
    static let regionPadding: CGFloat = 24

    /// The cascade: element under cursor → web content → window content →
    /// whole window. Always answers; provenance tells the truth about how
    /// precise the answer is. All rects share the global top-left space.
    static func chooseRegion(
        cursor: CGPoint,
        window: CGRect,
        ancestors: [Candidate],
        webArea: CGRect?,
        contentChildren: [Candidate],
        hint: RegionHint?,
        declaredEditor: CGRect? = nil
    ) -> (rect: CGRect, provenance: RegionProvenance) {
        if let declaredEditor, declaredEditor.width > 0, declaredEditor.height > 0,
           declaredEditor.intersects(window) {
            return (declaredEditor.intersection(window), .declaredEditor)
        }
        let windowArea = window.width * window.height
        let qualifying = ancestors.filter { candidate in
            let area = candidate.frame.width * candidate.frame.height
            return candidate.frame.width >= minimumRegionSize.width
                && candidate.frame.height >= minimumRegionSize.height
                && area <= maximumWindowShare * windowArea
        }

        // Hint match outranks everything: the user told us what they mean.
        if let hint, hint != .text {
            let hinted = qualifying.filter { matches($0, hint: hint) }
            let underCursor = hinted.filter { $0.frame.contains(cursor) }
            if let chosen = (underCursor.isEmpty ? hinted : underCursor)
                .min(by: { area($0) < area($1) }) {
                return (padded(chosen.frame, in: window), .elementUnderCursor)
            }
        }

        let preferred = qualifying.filter { preferredContainerRoles.contains($0.role) }
        if let chosen = (preferred.isEmpty ? qualifying : preferred)
            .min(by: { area($0) < area($1) }) {
            let rect = padded(chosen.frame, in: window)
            // A shallow strip at the window's top is chrome (toolbar, tab
            // bar), not content — fall through to the web area if one exists.
            let looksLikeChrome = rect.height < 100
                || rect.maxY <= window.minY + 120
            if !(looksLikeChrome && webArea != nil) {
                return (rect, .elementUnderCursor)
            }
        }

        if let webArea, webArea.width >= minimumRegionSize.width,
           webArea.height >= minimumRegionSize.height {
            return (webArea.intersection(window), .webContent)
        }

        if let content = contentChildren
            .filter({ preferredContainerRoles.contains($0.role)
                && area($0) >= 0.6 * windowArea })
            .max(by: { area($0) < area($1) }) {
            return (content.frame.intersection(window), .windowContent)
        }

        return (window, .wholeWindow)
    }

    private static func area(_ candidate: Candidate) -> CGFloat {
        candidate.frame.width * candidate.frame.height
    }

    private static func matches(_ candidate: Candidate, hint: RegionHint) -> Bool {
        switch hint {
        case .image:
            return candidate.role == "AXImage"
        case .video:
            let haystack = [candidate.role, candidate.subrole ?? "", candidate.description ?? ""]
                .joined(separator: " ").lowercased()
            return haystack.contains("video") || haystack.contains("player")
        case .text:
            return false
        }
    }

    static func padded(_ rect: CGRect, in window: CGRect) -> CGRect {
        rect.insetBy(dx: -regionPadding, dy: -regionPadding).intersection(window)
    }

    /// Maps a global-points content rect into pixel coordinates of a
    /// window-sized image, clamped to the image bounds.
    static func clampedCrop(content: CGRect, window: CGRect, imageSize: CGSize) -> CGRect {
        guard window.width > 0, window.height > 0 else {
            return CGRect(origin: .zero, size: imageSize)
        }
        let scaleX = imageSize.width / window.width
        let scaleY = imageSize.height / window.height
        let crop = CGRect(
            x: (content.origin.x - window.origin.x) * scaleX,
            y: (content.origin.y - window.origin.y) * scaleY,
            width: content.width * scaleX,
            height: content.height * scaleY)
        return crop.intersection(CGRect(origin: .zero, size: imageSize))
    }

    /// Proportional downscale so the long edge fits the cap; never upscales.
    static func downscaledSize(_ size: CGSize, longEdgeCap: CGFloat) -> CGSize {
        let longEdge = max(size.width, size.height)
        guard longEdge > longEdgeCap, longEdge > 0 else { return size }
        let scale = longEdgeCap / longEdge
        return CGSize(
            width: (size.width * scale).rounded(.down),
            height: (size.height * scale).rounded(.down))
    }

    /// The compression ladder: each rung is tried in order and the first result under
    /// `payloadCap` wins; the last rung is taken regardless.
    enum CaptureProfile {
        case fast
        case standard

        var ladder: [(longEdge: CGFloat, jpegQuality: CGFloat)] {
            switch self {
            case .fast:
                return [(1024, 0.6), (1024, 0.5), (896, 0.5)]
            case .standard:
                return ScreenRegionCapture.compressionLadder
            }
        }

        var payloadCap: Int {
            switch self {
            case .fast: return 200 * 1024
            case .standard: return ScreenRegionCapture.payloadCap
            }
        }
    }

    static let compressionLadder: [(longEdge: CGFloat, jpegQuality: CGFloat)] = [
        (1568, 0.8), (1568, 0.6), (1280, 0.6), (1024, 0.5),
    ]
    /// Client-side payload target; the server refuses at 8 MiB of base64.
    static let payloadCap = 500 * 1024

    // MARK: - Accessibility reads

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        AX.element(parent, attribute)
    }

    private static func string(_ parent: AXUIElement, _ attribute: String) -> String? {
        AX.string(parent, attribute)
    }

    /// `AX.frame` adds a `CFGetTypeID` check this file's original inline
    /// version skipped; the extra `size > 0` constraint stays here, since it
    /// is this file's own candidate-quality rule, not a general AX property.
    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let rect = AX.frame(of: element), rect.size.width > 0, rect.size.height > 0
        else { return nil }
        return rect
    }

    private static func candidate(from element: AXUIElement) -> Candidate? {
        guard let frame = frame(of: element) else { return nil }
        return Candidate(
            role: string(element, kAXRoleAttribute as String) ?? "",
            subrole: string(element, kAXSubroleAttribute as String),
            description: string(element, kAXDescriptionAttribute as String),
            frame: frame)
    }

    /// The ancestor chain from the element under the cursor up toward the
    /// window (innermost first, at most 8 hops), reduced to candidates.
    private static func ancestorCandidates(
        at cursor: CGPoint, in window: AXUIElement, processIdentifier: pid_t
    ) -> [Candidate] {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.5)
        var hit: AXUIElement?
        var hitRef: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(
            systemWide, Float(cursor.x), Float(cursor.y), &hitRef)
        if status == .success { hit = hitRef }

        var chain: [Candidate] = []
        var node = hit
        var hops = 0
        while let current = node, hops < 8 {
            if string(current, kAXRoleAttribute as String) == kAXWindowRole as String { break }
            if let candidate = candidate(from: current) { chain.append(candidate) }
            node = element(current, kAXParentAttribute as String)
            hops += 1
        }
        return chain
    }

    /// Bounded breadth-first search for the one largest AXWebArea — works
    /// for any app that exposes web content (Safari, Chrome, Arc, Electron).
    private static func webAreaFrame(in window: AXUIElement) -> CGRect? {
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var cursor = 0
        var best: CGRect?
        while cursor < queue.count, queue.count <= 1_500 {
            let (node, depth) = queue[cursor]
            cursor += 1
            if string(node, kAXRoleAttribute as String) == "AXWebArea",
               let rect = frame(of: node) {
                if best.map({ rect.width * rect.height > $0.width * $0.height }) ?? true {
                    best = rect
                }
            }
            guard depth < 14 else { continue }
            for child in AX.children(node) { queue.append((child, depth + 1)) }
        }
        return best
    }

    /// Direct and second-level children of the window, for the
    /// window-content rung (trimming toolbars off the whole-window answer).
    private static func contentChildCandidates(of window: AXUIElement) -> [Candidate] {
        var results: [Candidate] = []
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var cursor = 0
        while cursor < queue.count, queue.count <= 60 {
            let (node, depth) = queue[cursor]
            cursor += 1
            if depth > 0, let candidate = candidate(from: node) { results.append(candidate) }
            guard depth < 2 else { continue }
            for child in AX.children(node) { queue.append((child, depth + 1)) }
        }
        return results
    }

    /// Bounded search below `root` for elements matching the user's hint
    /// ("the image", "the video") — depth 4, at most 300 nodes.
    private static func hintedDescendants(
        matching hint: RegionHint, from root: AXUIElement
    ) -> [Candidate] {
        var results: [Candidate] = []
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var cursor = 0
        while cursor < queue.count, queue.count <= 300 {
            let (node, depth) = queue[cursor]
            cursor += 1
            if let candidate = candidate(from: node), matches(candidate, hint: hint) {
                results.append(candidate)
            }
            guard depth < 4 else { continue }
            for child in AX.children(node) { queue.append((child, depth + 1)) }
        }
        return results
    }

    private static func windowID(of window: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        guard _AXUIElementGetWindow(window, &id) == .success, id != 0 else { return nil }
        return id
    }

    // MARK: - ScreenCaptureKit + compression

    private static func captureCompressed(
        windowID: CGWindowID?,
        processIdentifier: pid_t,
        windowRect: CGRect,
        contentRect: CGRect,
        profile: CaptureProfile = .fast
    ) async throws -> Data {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
        } catch {
            throw Failure.screenRecordingUnavailable(error.localizedDescription)
        }
        let window = content.windows.first { candidate in
            if let windowID { return candidate.windowID == windowID }
            return candidate.owningApplication?.processID == processIdentifier
                && abs(candidate.frame.origin.x - windowRect.origin.x) < 2
                && abs(candidate.frame.origin.y - windowRect.origin.y) < 2
        }
        guard let window else {
            throw Failure.screenRecordingUnavailable(
                "the focused window is not visible to screen capture")
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width) * 2
        configuration.height = Int(window.frame.height) * 2
        configuration.showsCursor = false
        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: configuration)
        } catch {
            throw Failure.screenRecordingUnavailable(error.localizedDescription)
        }
        let crop = clampedCrop(
            content: contentRect,
            window: window.frame,
            imageSize: CGSize(width: image.width, height: image.height))
        let cropped = image.cropping(to: crop) ?? image

        var lastEncoded: Data?
        for rung in profile.ladder {
            let target = downscaledSize(
                CGSize(width: cropped.width, height: cropped.height),
                longEdgeCap: rung.longEdge)
            guard let scaled = resized(cropped, to: target),
                  let encoded = jpeg(scaled, quality: rung.jpegQuality) else { continue }
            lastEncoded = encoded
            if encoded.count <= profile.payloadCap { return encoded }
        }
        guard let encoded = lastEncoded else {
            throw Failure.screenRecordingUnavailable("the captured image could not be encoded")
        }
        return encoded
    }

    private static func resized(_ image: CGImage, to size: CGSize) -> CGImage? {
        let width = Int(size.width), height = Int(size.height)
        guard width > 0, height > 0 else { return nil }
        if width == image.width && height == image.height { return image }
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func jpeg(_ image: CGImage, quality: CGFloat) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(
            using: .jpeg, properties: [.compressionFactor: quality])
    }
}

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: inout CGWindowID) -> AXError
