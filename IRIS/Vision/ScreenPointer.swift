//
//  ScreenPointer.swift
//  IRIS — Vision + AI lane
//
//  "Show, don't do": capture the screen, ask a model WHERE a UI element is, and fly the
//  PointerOverlay arrow to it (ported from clicky). Two locate paths:
//   - Anthropic key set → one Messages API call with the computer-use tool (accurate
//     pixel coordinates at a Computer-Use-calibrated resolution).
//   - Otherwise → a plain vision prompt returning JSON {x,y} via `claude -p` / OpenAI.
//
//  Coordinate math (docs/algorithms.md → Screen pointing): image px (top-left origin)
//  → clamp → scale by screenFrame/imageSize → flip to AppKit global (bottom-left origin).
//  v1 points on the first/main display, matching ScreenCapture.
//

import Foundation
import AppKit

@MainActor
final class ScreenPointer {
    private let settings: Settings
    private let screenCapture: ScreenCapture
    private let costGovernor: CostGovernor?
    private let overlay = PointerOverlay()
    private let urlSession: URLSession = .shared

    init(settings: Settings, screenCapture: ScreenCapture, costGovernor: CostGovernor?) {
        self.settings = settings
        self.screenCapture = screenCapture
        self.costGovernor = costGovernor
    }

    // MARK: - Public API

    /// Find `query` on screen and point at it. Returns a short spoken result for the model.
    func point(at query: String, label: String?) async -> String {
        guard let shot = await screenCapture.captureForPointing() else {
            return "I couldn't capture the screen — Screen Recording permission may be off."
        }
        defer { try? FileManager.default.removeItem(atPath: shot.path) }

        guard let imagePoint = await locate(query: query, shot: shot) else {
            return "I couldn't find \(query) on the screen."
        }
        show(imagePoint: imagePoint, imageSize: shot.pixelSize,
             screenFrame: shot.screenFrame, label: label ?? query)
        return "I'm pointing at it now."
    }

    /// Show the pointer for an already-known image coordinate (the classic pipeline's
    /// [POINT:x,y:label] tags — coordinates are relative to `imageSize`).
    func show(imagePoint: CGPoint, imageSize: CGSize, screenFrame: CGRect, label: String?) {
        let target = Self.globalPoint(imagePoint: imagePoint, imageSize: imageSize,
                                      screenFrame: screenFrame)
        overlay.point(at: target, label: label, screenFrame: screenFrame)
    }

    /// Hide the pointer (e.g. on interrupt).
    func dismiss() { overlay.dismiss() }

    /// Image px (top-left origin) → AppKit global point (bottom-left origin).
    static func globalPoint(imagePoint: CGPoint, imageSize: CGSize,
                            screenFrame: CGRect) -> CGPoint {
        let xi = min(max(imagePoint.x, 0), imageSize.width - 1)
        let yi = min(max(imagePoint.y, 0), imageSize.height - 1)
        let px = xi * screenFrame.width / max(imageSize.width, 1)
        let py = yi * screenFrame.height / max(imageSize.height, 1)
        return CGPoint(x: screenFrame.minX + px, y: screenFrame.maxY - py)
    }

    // MARK: - Locating

    private func locate(query: String, shot: ScreenCapture.Shot) async -> CGPoint? {
        if let key = settings.anthropicAPIKey, !key.isEmpty {
            if let p = await locateViaComputerUse(query: query, shot: shot, apiKey: key) {
                return p
            }
            // fall through to the plain-vision paths on failure
        }
        return await locateViaVisionJSON(query: query, shot: shot)
    }

    /// One Messages API call with the computer-use tool: hand the model the screenshot and
    /// ask it to answer with a `mouse_move` to the element — its `coordinate` is our point.
    private func locateViaComputerUse(query: String, shot: ScreenCapture.Shot,
                                      apiKey: String) async -> CGPoint? {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages"),
              let imgData = try? Data(contentsOf: URL(fileURLWithPath: shot.path)) else {
            return nil
        }
        let w = Int(shot.pixelSize.width), h = Int(shot.pixelSize.height)
        let body: [String: Any] = [
            "model": settings.model,
            "max_tokens": 256,
            "tools": [[
                "type": "computer_20250124",
                "name": "computer",
                "display_width_px": w,
                "display_height_px": h,
            ]],
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image",
                     "source": ["type": "base64", "media_type": "image/png",
                                "data": imgData.base64EncodedString()]],
                    ["type": "text", "text":
                        "This is the current \(w)x\(h) screenshot of the display. Locate: \(query). "
                        + "Respond with a single computer tool call using the mouse_move action at "
                        + "the center of that element. Do not take a screenshot."],
                ],
            ]],
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("computer-use-2025-01-24", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = bodyData
        request.timeoutInterval = 30

        guard let (data, response) = try? await urlSession.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = obj["content"] as? [[String: Any]] else {
            IRISLog.log("pointer: computer-use locate failed (request/parse)")
            return nil
        }
        for block in blocks where block["type"] as? String == "tool_use" {
            guard let input = block["input"] as? [String: Any],
                  let coord = input["coordinate"] as? [Any], coord.count == 2,
                  let x = (coord[0] as? NSNumber)?.doubleValue,
                  let y = (coord[1] as? NSNumber)?.doubleValue else { continue }
            return CGPoint(x: x, y: y)
        }
        IRISLog.log("pointer: computer-use reply had no coordinate")
        return nil
    }

    /// Fallback: ask for bare JSON {x,y} pixel coordinates via `claude -p` (free).
    private func locateViaVisionJSON(query: String, shot: ScreenCapture.Shot) async -> CGPoint? {
        let w = Int(shot.pixelSize.width), h = Int(shot.pixelSize.height)
        let instruction = "In this \(w)x\(h) screenshot, find: \(query). Reply with ONLY a "
            + "compact JSON object {\"x\":<int>,\"y\":<int>} — the pixel coordinates of its "
            + "center. If it isn't visible, reply {}."

        let binary = settings.claudeBinary
        guard !binary.isEmpty, FileManager.default.isExecutableFile(atPath: binary) else {
            return nil
        }
        let prompt = "A screenshot is saved at this PNG path. Read it, then follow the "
            + "instruction.\n\(shot.path)\n\n\(instruction)"
        let result = await ClaudeProcessRunner.run(
            binary: binary, args: ["-p", "--model", settings.model, "--allowedTools", "Read"],
            prompt: prompt)
        guard result.ok else { return nil }
        return Self.parseXY(result.output)
    }

    /// Tolerantly pull {"x":…,"y":…} out of a model reply.
    static func parseXY(_ raw: String) -> CGPoint? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"),
              start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let x = (obj["x"] as? NSNumber)?.doubleValue,
              let y = (obj["y"] as? NSNumber)?.doubleValue else { return nil }
        return CGPoint(x: x, y: y)
    }
}
