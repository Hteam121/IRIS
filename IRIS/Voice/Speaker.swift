//
//  Speaker.swift
//  IRIS — Voice + Audio lane (Phase 1)
//
//  Text-to-speech via AVSpeechSynthesizer. Sets `AppState.isSpeaking` for the duration of
//  speech so `WakeWordDetector` stops transcribing IRIS's own voice (plan.md fix #5), and
//  calls `onFinished` when speech ends so AppDelegate (Phase 2) can return to idle / resume
//  listening.
//
//  Lane B owns this file; depends only on the frozen Phase 0 contract (`Settings`, `AppState`).
//

import Foundation
import AVFoundation

@MainActor
final class Speaker: NSObject {
    private let settings: Settings
    private weak var appState: AppState?
    private let synthesizer = AVSpeechSynthesizer()

    /// Called on the main actor when speech finishes or is cancelled.
    var onFinished: (() -> Void)?

    // Tuned constants — see docs/algorithms.md → Text-to-speech. Pitch sits at 1.0 for a
    // natural tone; the realism comes mostly from picking an enhanced/premium voice.
    private let pitchMultiplier: Float = 1.0
    private let volume: Float = 0.9

    /// The best available voice for the configured language, cached after first lookup.
    private lazy var preferredVoice: AVSpeechSynthesisVoice? = resolveVoice()

    init(settings: Settings, appState: AppState) {
        self.settings = settings
        self.appState = appState
        super.init()
        synthesizer.delegate = self
    }

    /// Pick the most natural voice we can: an explicit override if set, otherwise the
    /// highest-quality (premium → enhanced → default) installed voice for the language.
    /// Higher-quality voices may need a one-time download in System Settings → Accessibility
    /// → Spoken Content → System Voice; we gracefully fall back to whatever is installed.
    private func resolveVoice() -> AVSpeechSynthesisVoice? {
        if let id = settings.voiceIdentifier,
           let v = AVSpeechSynthesisVoice(identifier: id) {
            return v
        }

        let lang = settings.voice
        let langPrefix = String(lang.prefix(2)).lowercased()

        func quality(_ v: AVSpeechSynthesisVoice) -> Int {
            switch v.quality {
            case .premium: return 3
            case .enhanced: return 2
            default: return 1
            }
        }

        let matches = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language == lang || $0.language.lowercased().hasPrefix(langPrefix)
        }
        // Prefer exact-language match, then quality; avoids novelty voices ranking high.
        let best = matches.sorted { a, b in
            if (a.language == lang) != (b.language == lang) { return a.language == lang }
            return quality(a) > quality(b)
        }.first

        return best
            ?? AVSpeechSynthesisVoice(language: lang)
            ?? AVSpeechSynthesisVoice(language: Settings.defaultVoice)
    }

    /// Whether speech is currently in progress (used for barge-in decisions).
    var isSpeaking: Bool { synthesizer.isSpeaking }

    /// Speak `text`. Empty/whitespace input is a no-op that still invokes `onFinished`.
    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            onFinished?()
            return
        }

        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.rate = settings.ttsRate
        utterance.pitchMultiplier = pitchMultiplier
        utterance.volume = volume
        // Use the best resolved voice (explicit override → premium/enhanced → default).
        utterance.voice = preferredVoice
            ?? AVSpeechSynthesisVoice(language: settings.voice)
            ?? AVSpeechSynthesisVoice(language: Settings.defaultVoice)

        appState?.isSpeaking = true
        appState?.status = .speaking
        synthesizer.speak(utterance)
    }

    /// Stop any in-progress speech; the delegate resets `isSpeaking` and fires `onFinished`.
    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    fileprivate func handleSpeechEnded() {
        appState?.isSpeaking = false
        if appState?.status == .speaking {
            appState?.status = .idle
        }
        onFinished?()
    }
}

extension Speaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in self?.handleSpeechEnded() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in self?.handleSpeechEnded() }
    }
}
