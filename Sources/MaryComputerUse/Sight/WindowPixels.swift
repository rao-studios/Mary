//
//  WindowPixels.swift
//  MaryComputerUse
//
//  WHAT: One window's pixels, and the measured map back to the screen.
//  IN:   ScreenRegionCapture (the look), Sight/Vision (the page read)
//  OUT:  Frame — a CGImage plus its density and origin
//  PIN:  THE SCALE IS MEASURED, NEVER ASSUMED. This layer used to request
//        `width * 2` and believe it got 2x, which is wrong on a 1x external display and
//        wrong again on any future density — every rect derived from it drifts further
//        across the window. The only honest scale is image.width ÷ window.width after
//        the fact, checked against a whole number: a fractional one means the capture
//        was FITTED to something rather than rendered at native density.
//        ONE CAPTURE PATH FOR THE WHOLE LAYER. Two places that talk to ScreenCaptureKit
//        are two places that have to get the window match, the density and the
//        permission failure right, and only one of them would be watched.
//

import CoreGraphics
import Foundation
import ScreenCaptureKit

public enum WindowPixels {

    /// One window's pixels and everything needed to place them back on screen.
    public struct Frame: @unchecked Sendable {
        public let image: CGImage
        /// The window's frame in global top-left points, as ScreenCaptureKit reports it.
        public let windowFrame: CGRect
        /// Measured pixels per point.
        public let pixelsPerPoint: Double
        public let windowTitle: String
        public let capturedAt: Date

        public init(
            image: CGImage, windowFrame: CGRect, pixelsPerPoint: Double,
            windowTitle: String, capturedAt: Date = Date()
        ) {
            self.image = image
            self.windowFrame = windowFrame
            self.pixelsPerPoint = pixelsPerPoint
            self.windowTitle = windowTitle
            self.capturedAt = capturedAt
        }

        /// A rect in global screen points, in this image's pixel coordinates.
        public func pixelRect(of contentRect: CGRect) -> CGRect {
            let scale = CGFloat(pixelsPerPoint)
            return CGRect(
                x: (contentRect.origin.x - windowFrame.origin.x) * scale,
                y: (contentRect.origin.y - windowFrame.origin.y) * scale,
                width: contentRect.width * scale,
                height: contentRect.height * scale)
                .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }

        /// Where this image's pixel (0, 0) sits, in global screen points.
        public var origin: CGPoint { windowFrame.origin }
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case screenRecordingUnavailable(String)
        case windowNotVisible
        /// The capture was fitted rather than rendered at native density.
        case oddScale(Double)

        public var errorDescription: String? {
            switch self {
            case .screenRecordingUnavailable(let reason):
                return "Mary needs Screen Recording permission to see the screen: \(reason)"
            case .windowNotVisible:
                return "That window is not visible to screen capture."
            case .oddScale(let scale):
                return "The capture came back at \(scale) pixels per point — it was fitted, not rendered."
            }
        }
    }

    /// One window's pixels. `windowID` identifies it exactly when the caller has one;
    /// `axFrame` pairs by geometry otherwise, so a walk of window A is never matched
    /// against a capture of window B.
    public static func capture(
        pid: pid_t,
        windowID: CGWindowID? = nil,
        matching axFrame: CGRect? = nil
    ) async throws -> Frame {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
        } catch {
            ComputerUseMonitor.shared.note(
                lane: .sight, refused: "capture", pid: pid,
                reason: .screenRecordingUnavailable(error.localizedDescription))
            throw Failure.screenRecordingUnavailable(error.localizedDescription)
        }

        guard let window = choose(
            from: content.windows, pid: pid, windowID: windowID, axFrame: axFrame)
        else {
            ComputerUseMonitor.shared.note(
                lane: .sight, refused: "capture", pid: pid, reason: .pageNotVisible)
            throw Failure.windowNotVisible
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let density = filter.pointPixelScale
        configuration.width = Int(filter.contentRect.width * CGFloat(density))
        configuration.height = Int(filter.contentRect.height * CGFloat(density))
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.ignoreShadowsSingleWindow = true

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: configuration)
        } catch {
            ComputerUseMonitor.shared.note(
                lane: .sight, refused: "capture", pid: pid,
                reason: .screenRecordingUnavailable(error.localizedDescription))
            throw Failure.screenRecordingUnavailable(error.localizedDescription)
        }

        guard window.frame.width > 0 else { throw Failure.windowNotVisible }
        let scale = Double(image.width) / Double(window.frame.width)
        guard abs(scale - scale.rounded()) < 0.01 else {
            ComputerUseMonitor.shared.note(
                lane: .sight, refused: "capture", pid: pid,
                reason: .other("capture scale \(scale) is not a whole number"))
            throw Failure.oddScale(scale)
        }

        ComputerUseMonitor.shared.note(
            lane: .sight, act: "capture", pid: pid,
            detail: "\(image.width)×\(image.height) @\(Int(scale))x")
        return Frame(
            image: image,
            windowFrame: window.frame,
            pixelsPerPoint: scale,
            windowTitle: window.title ?? "")
    }

    /// Which on-screen window a capture request means. Pure, so the ladder is testable
    /// without a display: exact id, then a geometry pairing, then the largest window
    /// the process owns.
    static func choose(
        from windows: [SCWindow], pid: pid_t, windowID: CGWindowID?, axFrame: CGRect?
    ) -> SCWindow? {
        if let windowID, let exact = windows.first(where: { $0.windowID == windowID }) {
            return exact
        }
        let owned = windows.filter { window in
            window.owningApplication?.processID == pid
                && window.frame.width > 120 && window.frame.height > 120
        }
        guard !owned.isEmpty else { return nil }
        if let axFrame, let paired = owned.first(where: { window in
            abs(window.frame.origin.x - axFrame.origin.x) < 2
                && abs(window.frame.origin.y - axFrame.origin.y) < 2
                && abs(window.frame.width - axFrame.width) < 2
                && abs(window.frame.height - axFrame.height) < 2
        }) {
            return paired
        }
        return owned.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    /// A region of a captured frame, in global screen points. Nil when the region does
    /// not overlap the window at all.
    public static func crop(_ frame: Frame, to contentRect: CGRect) -> CGImage? {
        let pixels = frame.pixelRect(of: contentRect).integral
        guard pixels.width >= 1, pixels.height >= 1 else { return nil }
        return frame.image.cropping(to: pixels)
    }
}
