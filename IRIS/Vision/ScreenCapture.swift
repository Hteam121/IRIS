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

    private let lock = NSLock()
    private var counter = 0

    public init() {}

    /// Capture the first/main display and write it to `NSTemporaryDirectory()/iris-shot-<n>.png`.
    /// - Returns: the file path, or `nil` on any failure.
    public func capture() async -> String? {
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
            return writePNG(cgImage)
        } catch {
            return nil
        }
    }

    // MARK: - PNG export

    /// Downscale (if needed) and write the image as PNG at its real pixel size.
    private func writePNG(_ cgImage: CGImage) -> String? {
        let image = downscaledIfNeeded(cgImage)

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
        let w = Int((CGFloat(image.width) * ratio).rounded())
        let h = Int((CGFloat(image.height) * ratio).rounded())

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
