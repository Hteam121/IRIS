//
//  VoiceProviders.swift
//  IRIS — pluggable voice provider seams
//
//  Protocol seams so STT/TTS backends can be swapped without touching the pipeline:
//  today STT is the on-device SFSpeechRecognizer stack (free) and TTS is OpenAI
//  gpt-4o-mini-tts with the AVSpeechSynthesizer fallback inside `Speaker`; an
//  ElevenLabs or AssemblyAI implementation is a drop-in conformance later.
//

import Foundation

/// Synthesizes speech audio for `text`, or nil on failure (caller falls back to the
/// on-device AVSpeechSynthesizer).
@MainActor
protocol TTSProvider {
    func synthesize(text: String, settings: Settings) async -> Data?
}

/// The OpenAI neural TTS backend (gpt-4o-mini-tts; see OpenAITTS.swift).
struct OpenAITTSProvider: TTSProvider {
    func synthesize(text: String, settings: Settings) async -> Data? {
        await OpenAITTS.synthesize(text: text, settings: settings)
    }
}
