//
//  ScreenCapture.swift
//  IRIS — Vision + AI lane (Phase 1)
//
//  Captures the current display to a temp PNG and returns its path. Downstream,
//  the path is passed to `IRISBrain` (a temp PNG for the CLI path, base64-encoded
//  for the API path).
//
//  plan.md fix #6 / docs/algorithms.md → Screen capture:
//   - Use `SCScreenshotManager.captureImage` (macOS 14+).
//   - Configure capture at the display's *pixel* dimensions (points × backing scale).
//   - Build the bitmap at the real pixel size and export PNG (never `.zero` / TIFF).
//   - Optionally downscale to ~1568 px longest edge before sending to AI.
//

import Foundation
import ScreenCaptureKit
import CoreGraphics
import AppKit

/// Captures the main display to a temp PNG file. Best-effort: returns `nil` if the
/// platform is too old, Screen Recording permission is missing, or capture fails.
public final class ScreenCapture {
    /// Longest-edge cap for the exported image (Anthropic vision sweet spot); keeps
    /// token count / latency down while preserving aspect ratio.
    private static let maxLongestEdge = 1568

    /// A captured screenshot plus the geometry needed to map its pixel coordinates back
    /// onto the screen (see ScreenPointer / docs/algorithms.md → Screen pointing).
    public struct Shot: Sendable {
        /// Temp PNG file path.
        public let path: String
        /// Exported image size in pixels.
        public let pixelSize: CGSize
        /// AppKit global frame (points, bottom-left origin) of the captured display.
        public let screenFrame: CGRect
    }

    private let lock = NSLock()
    private var counter = 0

    public init() {}

    /// Capture the first/main display and write it to `NSTemporaryDirectory()/iris-shot-<n>.png`.
    /// - Returns: the file path, or `nil` on any failure.
    public func capture() async -> String? {
        await captureShot(targetSize: nil)?.path
    }

    /// Like `capture()`, but also returns the exported pixel size + display frame so image
    /// coordinates (e.g. [POINT:x,y] tags) can be mapped back onto the screen.
    public func captureWithInfo() async -> Shot? {
        await captureShot(targetSize: nil)
    }

    /// Capture at a Computer-Use-friendly resolution chosen by the display's aspect ratio
    /// (docs/algorithms.md → Screen pointing): 4:3 → 1024×768, 16:10 → 1280×800,
    /// 16:9 → 1366×768. Anthropic's computer-use models are calibrated near these sizes;
    /// an off-aspect resize would distort the X axis.
    public func captureForPointing() async -> Shot? {
        await captureShot(targetSize: nil, pickPointingResolution: true)
    }

    private func captureShot(targetSize: CGSize?,
                             pickPointingResolution: Bool = false) async -> Shot? {
        guard #available(macOS 14.0, *) else {
            // SCScreenshotManager is macOS 14+. Older systems get no vision (best-effort).
            return nil
        }
        do {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first else { return nil }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            // SCStreamConfiguration dimensions are in pixels; SCDisplay width/height
            // are points, so multiply by the display's backing scale factor.
            let scale = backingScale(forDisplayID: display.displayID)
            config.width = Int(CGFloat(display.width) * scale)
            config.height = Int(CGFloat(display.height) * scale)
            config.showsCursor = true

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            let size = pickPointingResolution
                ? Self.pointingResolution(for: CGSize(width: cgImage.width, height: cgImage.height))
                : targetSize
            let image = size.map { resized(cgImage, to: $0) } ?? downscaledIfNeeded(cgImage)
            guard let path = writePNG(image) else { return nil }
            return Shot(path: path,
                        pixelSize: CGSize(width: image.width, height: image.height),
                        screenFrame: screenFrame(forDisplayID: display.displayID))
        } catch {
            return nil
        }
    }

    /// Nearest Computer-Use resolution by aspect ratio.
    static func pointingResolution(for pixels: CGSize) -> CGSize {
        let candidates: [CGSize] = [
            CGSize(width: 1024, height: 768),    // 4:3
            CGSize(width: 1280, height: 800),    // 16:10
            CGSize(width: 1366, height: 768),    // 16:9
        ]
        let ratio = pixels.width / max(pixels.height, 1)
        return candidates.min {
            abs($0.width / $0.height - ratio) < abs($1.width / $1.height - ratio)
        } ?? candidates[1]
    }

    // MARK: - PNG export

    /// Write the image as PNG at its real pixel size.
    private func writePNG(_ image: CGImage) -> String? {
        // NSBitmapImageRep(cgImage:) preserves the true pixel dimensions; that's the
        // reliable PNG path (plan.md fix #6 — don't build an NSImage with `.zero`).
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: image.width, height: image.height)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }

        let n = nextIndex()
        let path = NSTemporaryDirectory() + "iris-shot-\(n).png"
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return path
        } catch {
            return nil
        }
    }

    /// Cap the longest edge at `maxLongestEdge`, preserving aspect ratio. Best-effort:
    /// returns the original image if the resize can't be performed.
    private func downscaledIfNeeded(_ image: CGImage) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > Self.maxLongestEdge else { return image }

        let ratio = CGFloat(Self.maxLongestEdge) / CGFloat(longest)
        return resized(image, to: CGSize(width: (CGFloat(image.width) * ratio).rounded(),
                                         height: (CGFloat(image.height) * ratio).rounded()))
    }

    /// Resize to an exact pixel size. Best-effort: returns the original on failure.
    private func resized(_ image: CGImage, to size: CGSize) -> CGImage {
        let w = Int(size.width), h = Int(size.height)
        guard w > 0, h > 0, w != image.width || h != image.height else { return image }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    // MARK: - Helpers

    /// AppKit global frame (bottom-left origin) of the NSScreen matching a display id;
    /// falls back to the main screen's frame.
    private func screenFrame(forDisplayID displayID: CGDirectDisplayID) -> CGRect {
        for screen in NSScreen.screens {
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            if let num = screen.deviceDescription[key] as? CGDirectDisplayID, num == displayID {
                return screen.frame
            }
        }
        return NSScreen.main?.frame ?? .zero
    }

    /// Backing scale factor for the NSScreen that matches a given `CGDirectDisplayID`.
    private func backingScale(forDisplayID displayID: CGDirectDisplayID) -> CGFloat {
        for screen in NSScreen.screens {
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            if let num = screen.deviceDescription[key] as? CGDirectDisplayID, num == displayID {
                return screen.backingScaleFactor
            }
        }
        return NSScreen.main?.backingScaleFactor ?? 2.0
    }

    private func nextIndex() -> Int {
        lock.lock(); defer { lock.unlock() }
        counter += 1
        return counter
    }
}
