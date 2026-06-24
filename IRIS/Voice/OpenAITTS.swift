//
//  OpenAITTS.swift
//  IRIS — Voice + Audio lane
//
//  Synthesizes a natural, human-sounding voice via OpenAI's text-to-speech endpoint
//  (/v1/audio/speech). Returns MP3 audio data that `Speaker` plays with AVAudioPlayer.
//  Used when an OpenAI API key is set; `Speaker` falls back to AVSpeechSynthesizer otherwise
//  or if a request fails.
//

import Foundation

enum OpenAITTS {
    /// Synthesize `text` to MP3 audio. Returns nil if no key, a non-2xx status, or a network
    /// error (caller falls back to the system voice).
    static func synthesize(text: String, settings: Settings) async -> Data? {
        guard let key = settings.openAIAPIKey, !key.isEmpty,
              let url = URL(string: "https://api.openai.com/v1/audio/speech") else {
            return nil
        }

        var body: [String: Any] = [
            "model": settings.ttsModel,
            "voice": settings.ttsVoice,
            "input": text,
            "response_format": "mp3",
            "speed": 1.0,
        ]
        // gpt-4o-mini-tts accepts an `instructions` field to steer tone; harmless on models
        // that ignore it.
        if !settings.ttsInstructions.isEmpty {
            body["instructions"] = settings.ttsInstructions
        }
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            guard (200..<300).contains(http.statusCode) else {
                let msg = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
                NSLog("[IRIS] OpenAI TTS status \(http.statusCode): \(msg)")
                return nil
            }
            return data
        } catch {
            if !(error is CancellationError) {
                NSLog("[IRIS] OpenAI TTS error: \(error.localizedDescription)")
            }
            return nil
        }
    }
}
