//
//  LocalBrain.swift
//  IRIS — local-first answering (ported from OpenJarvis's local-first routing)
//
//  Free, on-device/LAN model clients used by LocalRouter for simple text questions before
//  paying for the cloud. Backends, in preference order:
//   - Apple Foundation Models (macOS 26+, zero setup) when the SDK + device support it.
//   - Ollama at `settings.ollamaURL` (`/api/chat`, non-streaming).
//
//  A slow local answer must never feel worse than the cloud: the availability probe times
//  out in 1.5s (result cached 60s) and the request itself in 8s
//  (docs/algorithms.md → Local routing).
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

@MainActor
final class LocalBrain {
    // Tuned constants — see docs/algorithms.md → Local routing.
    static let probeTimeout: TimeInterval = 1.5
    static let probeCacheSeconds: TimeInterval = 60
    static let requestTimeout: TimeInterval = 8

    private let settings: Settings
    private let urlSession: URLSession
    private var lastProbe: (at: Date, ok: Bool)?
    /// Model names the Ollama server reported on the last probe — used to fall back to an
    /// installed model when the configured `localModel` isn't pulled.
    private var ollamaModels: [String] = []

    init(settings: Settings) {
        self.settings = settings
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Self.requestTimeout
        self.urlSession = URLSession(configuration: config)
    }

    /// Whether any local backend can answer right now (probe cached 60s so a stopped
    /// Ollama never adds latency to every command).
    func isAvailable() async -> Bool {
        if appleModelAvailable { return true }
        if let lastProbe, Date().timeIntervalSince(lastProbe.at) < Self.probeCacheSeconds {
            return lastProbe.ok
        }
        let ok = await probeOllama()
        lastProbe = (Date(), ok)
        return ok
    }

    /// Answer with the preferred available backend. Nil on error/timeout/no backend.
    func answer(system: String, transcript: String,
                history: [[String: String]]) async -> String? {
        if appleModelAvailable {
            if let reply = await answerAppleFM(system: system, transcript: transcript,
                                               history: history) {
                return reply
            }
            // fall through to Ollama on failure
        }
        return await answerOllama(system: system, transcript: transcript, history: history)
    }

    // MARK: - Apple Foundation Models (macOS 26+)

    private var appleModelAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.availability == .available
        }
        #endif
        return false
    }

    private func answerAppleFM(system: String, transcript: String,
                               history: [[String: String]]) async -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            // Fold the short history into the prompt (the session API is single-threaded here).
            var prompt = ""
            for turn in history {
                let who = (turn["role"] == "assistant") ? Persona.name : "User"
                prompt += "\(who): \(turn["content"] ?? "")\n"
            }
            prompt += "User: \(transcript)"
            let session = LanguageModelSession(instructions: system)
            let reply = try? await session.respond(to: prompt)
            return reply?.content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #endif
        return nil
    }

    // MARK: - Ollama

    private func probeOllama() async -> Bool {
        guard let url = URL(string: settings.ollamaURL + "/api/tags") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.probeTimeout
        guard let (data, response) = try? await urlSession.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return false }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let models = obj["models"] as? [[String: Any]] {
            ollamaModels = models.compactMap { $0["name"] as? String }
        }
        return !ollamaModels.isEmpty
    }

    /// The configured model when the server has it; otherwise the first installed model
    /// (so local routing works out of the box regardless of which model was pulled).
    private var resolvedOllamaModel: String {
        let wanted = settings.localModel
        if ollamaModels.isEmpty { return wanted }
        if ollamaModels.contains(where: { $0 == wanted || $0.hasPrefix(wanted + ":") }) {
            return wanted
        }
        return ollamaModels[0]
    }

    private func answerOllama(system: String, transcript: String,
                              history: [[String: String]]) async -> String? {
        guard let url = URL(string: settings.ollamaURL + "/api/chat") else { return nil }

        var messages: [[String: String]] = [["role": "system", "content": system]]
        messages += history.map {
            ["role": $0["role"] ?? "user", "content": $0["content"] ?? ""]
        }
        messages.append(["role": "user", "content": transcript])

        let body: [String: Any] = [
            "model": resolvedOllamaModel,
            "messages": messages,
            "stream": false,
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        request.timeoutInterval = Self.requestTimeout

        guard let (data, response) = try? await urlSession.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = obj["message"] as? [String: Any],
              let content = message["content"] as? String else {
            // A failed chat call usually means the model isn't pulled / server just died —
            // invalidate the cached probe so we recheck soon rather than failing for 60s.
            lastProbe = nil
            return nil
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
