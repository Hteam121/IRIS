//
//  Speaker.swift
//  IRIS — Voice + Audio lane (Phase 1)
//
//  Text-to-speech. Primary path: OpenAI neural TTS (natural voice) played via AVAudioPlayer
//  when an OpenAI key is set; fallback: the built-in AVSpeechSynthesizer (offline, robotic).
//  Sets `AppState.isSpeaking` for the duration of speech so the wake detector handles barge-in
//  correctly, and calls `onFinished` when speech ends so AppDelegate returns to idle / listens.
//
//  All spoken output flows through a serialized queue (`enqueue`) so concurrent foreground
//  answers and agent announcements never overlap. A `generation` counter + suppression flag keep
//  state consistent when an utterance is replaced or stopped mid-flight (incl. async TTS fetch).
//
//  Lane B owns this file; depends only on the frozen Phase 0 contract (`Settings`, `AppState`).
//

import Foundation
@preconcurrency import AVFoundation

@MainActor
final class Speaker: NSObject {
    private let settings: Settings
    private weak var appState: AppState?

    private let synthesizer = AVSpeechSynthesizer()   // fallback (offline)
    private var audioPlayer: AVAudioPlayer?           // OpenAI neural TTS playback
    private var ttsTask: Task<Void, Never>?           // in-flight OpenAI synthesis fetch

    /// Budget meter. Gates neural TTS off in the `.free` tier (→ on-device) and records the
    /// per-synthesis character cost. Nil ⇒ unmetered (always allowed).
    private weak var costGovernor: CostGovernor?

    /// Called on the main actor when speech finishes or is cancelled.
    var onFinished: (() -> Void)?

    /// Pending spoken output (foreground answers + agent announcements), spoken one at a time.
    private var announcementQueue: [String] = []

    /// True while speaking OR fetching audio — gates the queue so lines don't overlap.
    private var isBusy = false
    /// Bumped on each new utterance and on stop(), so a stale async fetch result is discarded.
    private var generation = 0
    /// Set when we cancel the synthesizer to replace/stop, so its didCancel callback is ignored.
    private var suppressNextSynthCallback = false

    // Tuned constants — see docs/algorithms.md → Text-to-speech. Volume sits a little below
    // max so the mic picks up the "hey iris" barge-in over IRIS's own speaker output.
    private let pitchMultiplier: Float = 1.0
    private let volume: Float = 0.8

    /// The best available system voice (fallback path), cached after first lookup.
    private lazy var preferredVoice: AVSpeechSynthesisVoice? = resolveVoice()

    init(settings: Settings, appState: AppState, costGovernor: CostGovernor? = nil) {
        self.settings = settings
        self.appState = appState
        self.costGovernor = costGovernor
        super.init()
        synthesizer.delegate = self
    }

    /// Use OpenAI neural TTS only when enabled, keyed, AND the budget tier still allows it
    /// (the `.free` tier forces the offline voice so a spent budget can't be exceeded).
    private var useOpenAI: Bool {
        settings.openAITTSEnabled
            && !(settings.openAIAPIKey ?? "").isEmpty
            && (costGovernor?.allowsNeuralTTS ?? true)
    }

    /// Whether speech is currently in progress or being prepared.
    var isSpeaking: Bool { isBusy }

    // MARK: - Public API

    /// Speak `text` immediately, interrupting any current speech. Most callers should prefer
    /// `enqueue`. Empty input is a no-op that still invokes `onFinished`.
    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { onFinished?(); return }
        speakUtterance(trimmed)
    }

    /// Queue a line to speak when the speaker is next idle, so concurrent foreground answers and
    /// agent announcements are spoken in sequence without overlapping.
    func enqueue(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        announcementQueue.append(trimmed)
        if !isBusy { speakNext() }
    }

    /// Stop all speech and clear the queue (barge-in / explicit interrupt).
    func stop() {
        announcementQueue.removeAll()
        generation += 1                 // invalidate any in-flight fetch
        stopOutputs()
        finishCurrent()                 // reset state + notify (queue is empty → no next)
    }

    // MARK: - Internals

    private func speakNext() {
        guard !isBusy, !announcementQueue.isEmpty else { return }
        speakUtterance(announcementQueue.removeFirst())
    }

    private func speakUtterance(_ text: String) {
        generation += 1
        let gen = generation
        stopOutputs()                   // silently stop whatever is current (callbacks ignored)

        isBusy = true
        appState?.isSpeaking = true
        appState?.status = .speaking
        appState?.spokenText = text

        if useOpenAI {
            ttsTask = Task { [weak self] in
                guard let self else { return }
                let data = await OpenAITTS.synthesize(text: text, settings: self.settings)
                if gen != self.generation { return }     // superseded or stopped while fetching
                if let data, self.play(data) {
                    self.costGovernor?.recordTTS(characters: text.count)
                    return
                }
                self.speakSystem(text)                    // fall back on failure
            }
        } else {
            speakSystem(text)
        }
    }

    /// Stop current synth/player/fetch WITHOUT advancing the queue. Synth's didCancel is
    /// suppressed; AVAudioPlayer.stop() doesn't call its delegate, so neither fires a finish.
    private func stopOutputs() {
        ttsTask?.cancel()
        ttsTask = nil
        if synthesizer.isSpeaking {
            suppressNextSynthCallback = true
            synthesizer.stopSpeaking(at: .immediate)
        }
        audioPlayer?.stop()
        audioPlayer = nil
    }

    @discardableResult
    private func play(_ data: Data) -> Bool {
        do {
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            player.volume = volume
            audioPlayer = player
            player.prepareToPlay()
            player.play()
            return true
        } catch {
            NSLog("[IRIS] audio playback failed: \(error.localizedDescription)")
            return false
        }
    }

    private func speakSystem(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = settings.ttsRate
        utterance.pitchMultiplier = pitchMultiplier
        utterance.volume = volume
        utterance.voice = preferredVoice
            ?? AVSpeechSynthesisVoice(language: settings.voice)
            ?? AVSpeechSynthesisVoice(language: Settings.defaultVoice)
        synthesizer.speak(utterance)
    }

    /// Reset speaking state and either speak the next queued line, or — when nothing's left —
    /// notify `onFinished` (so AppDelegate only acts once IRIS has fully finished talking).
    private func finishCurrent() {
        audioPlayer = nil
        isBusy = false
        appState?.isSpeaking = false
        appState?.spokenText = ""

        if !announcementQueue.isEmpty {
            speakNext()           // more to say — stay "speaking"
            return
        }
        if appState?.status == .speaking {
            appState?.status = .idle
        }
        onFinished?()             // truly done talking
    }

    private func synthEnded() {
        if suppressNextSynthCallback {
            suppressNextSynthCallback = false
            return
        }
        finishCurrent()
    }

    private func playerEnded() {
        // Only the current player can reach here: replacing/stopping a player uses
        // AVAudioPlayer.stop(), which does NOT call this delegate — so no stale callbacks.
        finishCurrent()
    }

    // MARK: - Voice resolution (fallback path)

    /// Pick the most natural system voice: an explicit override, else highest-quality installed.
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
        let best = matches.sorted { a, b in
            if (a.language == lang) != (b.language == lang) { return a.language == lang }
            return quality(a) > quality(b)
        }.first

        return best
            ?? AVSpeechSynthesisVoice(language: lang)
            ?? AVSpeechSynthesisVoice(language: Settings.defaultVoice)
    }
}

extension Speaker: AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in self?.synthEnded() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in self?.synthEnded() }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in self?.playerEnded() }
    }
}
