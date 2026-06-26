//
//  OpenAIVision.swift
//  IRIS — Vision + AI lane
//
//  One place for the gpt-4o chat-completions "send a screenshot, get an answer" HTTP call. Both the
//  reactive screen-rule matcher (`ScreenRuleEngine.matchRule`) and the realtime screen-vision
//  fallback (`RealtimeTools.describeScreenOpenAI`) used to carry their own copy of this request
//  plumbing (URL, Bearer auth, base64 data URL, timeout, choices→message→content parsing); this
//  centralizes it so they only differ in prompt / json-mode / token budget and how they read the
//  reply.
//
//  Metering is intentionally left to callers: `complete` returns the raw `usage` object so the
//  caller records it against the CostGovernor exactly when it used to (right after a valid HTTP
//  response, whether or not the content parsed).
//

import Foundation

@MainActor
enum OpenAIVision {

    /// The result of one vision call. `content` is the assistant message text (nil if the response
    /// had no parseable content); `usage` is the token-usage object for metering (nil if absent).
    struct Reply {
        let content: String?
        let usage: [String: Any]?
    }

    /// Make one gpt-4o chat-completions call with a single screenshot. Returns `nil` only when there
    /// was no usable JSON response at all (transport error, non-2xx, or non-JSON body) — i.e. nothing
    /// to meter; otherwise a `Reply` whose `usage` should be metered even if `content` is nil.
    static func complete(imageData: Data, instruction: String, apiKey: String,
                         maxTokens: Int, jsonMode: Bool = false,
                         timeout: TimeInterval = 30) async -> Reply? {
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else { return nil }

        let b64 = imageData.base64EncodedString()
        var body: [String: Any] = [
            "model": "gpt-4o",
            "max_tokens": maxTokens,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": instruction],
                    ["type": "image_url", "image_url": ["url": "data:image/png;base64,\(b64)"]],
                ],
            ]],
        ]
        if jsonMode { body["response_format"] = ["type": "json_object"] }

        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        req.timeoutInterval = timeout

        guard let (respData, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: respData) as? [String: Any] else {
            return nil
        }
        let choices = obj["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        let content = message?["content"] as? String
        return Reply(content: content, usage: obj["usage"] as? [String: Any])
    }
}
