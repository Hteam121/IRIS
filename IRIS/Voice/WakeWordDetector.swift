//
//  WakeWordDetector.swift
//  IRIS — Voice + Audio lane (Phase 1)
//
//  Continuous "hey iris" wake-word listener with command capture. Built on
//  AVAudioEngine + SFSpeechRecognizer with a ~50s session-restart timer (the recognizer
//  caps near 60s).
//
//  Self-hearing gate: the detector mirrors `AppState.isSpeaking` (Combine) into a
//  lock-guarded `muted` flag that the realtime audio tap reads, and skips appending mic
//  buffers while IRIS's own TTS is playing — so IRIS never transcribes its own voice
//  (plan.md fix #5).
//
//  Flow (see docs/algorithms.md → wake word):
//    • Listen continuously; lowercase-`contains` match on the wake phrase.
//    • Once heard, keep accumulating the same utterance until the speaker pauses
//      (settle timer). Strip the wake-phrase prefix → that remainder is the command
//      ("hey iris what time is it" in one breath).
//    • If nothing followed the wake phrase ("hey iris" then a pause), hand off to
//      `Transcriber` to capture the command as a fresh utterance.
//    • Deliver the final command via `onWakeWordDetected`; AppDelegate (Phase 2) wires
//      that to screen capture → IRISBrain.ask → Speaker.speak.
//
//  Lane B owns this file; depends on the frozen Phase 0 contract (`Settings`, `AppState`)
//  and its lane-mate `Transcriber`.
//

import Foundation
import AVFoundation
import Speech
import Combine

@MainActor
final class WakeWordDetector {
    private let settings: Settings
    private weak var appState: AppState?

    private let recognizer: SFSpeechRecognizer?
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let transcriber: Transcriber

    // Self-hearing gate (plan.md fix #5): `AppState.isSpeaking` is mirrored into `muted`
    // while IRIS talks. The realtime audio tap reads it under `muteLock` and skips
    // appending buffers, so the recognizer never transcribes IRIS's own TTS.
    private var cancellables = Set<AnyCancellable>()
    private let muteLock = NSLock()
    private var muted = false

    private var isMuted: Bool {
        muteLock.lock(); defer { muteLock.unlock() }
        return muted
    }
    private func setMuted(_ value: Bool) {
        muteLock.lock(); muted = value; muteLock.unlock()
    }

    /// Fires (on the main actor) with the user's command, wake phrase already stripped.
    var onWakeWordDetected: ((String) -> Void)?

    private var isRunning = false
    private var capturing = false          // in the fresh-utterance command capture
    private var awaitingSettle = false     // wake heard; waiting for the utterance to end
    private var latestWakeTranscript = ""
    private var generation = 0             // invalidates callbacks from superseded sessions

    private var restartTimer: Timer?
    private var settleTimer: Timer?

    // Tuned constants — see docs/algorithms.md → wake word / command capture.
    private let bufferSize: AVAudioFrameCount = 1024
    private let restartInterval: TimeInterval = 50.0   // restart before the ~60s recognizer cap
    private let rearmDebounce: TimeInterval = 0.5      // wait before re-arming after a detection
    private let settleTimeout: TimeInterval = 1.2      // end-of-utterance pause after the wake word

    init(settings: Settings, appState: AppState) {
        self.settings = settings
        self.appState = appState
        let locale = Locale(identifier: settings.voice)
        self.recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
        self.transcriber = Transcriber(settings: settings)

        // Mirror TTS state into the mute flag the realtime tap consults.
        appState.$isSpeaking
            .receive(on: DispatchQueue.main)
            .sink { [weak self] speaking in self?.setMuted(speaking) }
            .store(in: &cancellables)
    }

    // MARK: - Authorization

    /// Request Speech Recognition + Microphone access. Call once before `start()`.
    static func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { speechStatus in
            let speechOK = (speechStatus == .authorized)
            AVCaptureDevice.requestAccess(for: .audio) { micOK in
                DispatchQueue.main.async { completion(speechOK && micOK) }
            }
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        startSession()
    }

    func stop() {
        isRunning = false
        capturing = false
        awaitingSettle = false
        transcriber.cancel()
        stopSession()
    }

    // MARK: - Recognition session

    private func startSession() {
        guard isRunning, !capturing else { return }
        guard let recognizer, recognizer.isAvailable else {
            NSLog("[IRIS] startSession aborted — recognizer unavailable (recognizer=\(recognizer != nil), available=\(recognizer?.isAvailable ?? false))")
            return
        }

        teardownRecognition()
        awaitingSettle = false
        latestWakeTranscript = ""

        // Bring up the mic engine first. If the hardware isn't ready (invalid format,
        // mid-handoff with the Transcriber), retry shortly instead of crashing.
        guard ensureEngineRunning() else {
            scheduleEngineRetry()
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        let gen = generation
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                if let result {
                    self.handleTranscript(result.bestTranscription.formattedString)
                }
                if error != nil {
                    // Session ended/expired. Re-arm after a short delay so an immediate,
                    // repeated error (e.g. recognizer hiccup) can't spin a tight CPU loop.
                    if self.isRunning && !self.capturing {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                            guard let self, self.isRunning, !self.capturing else { return }
                            self.startSession()
                        }
                    }
                }
            }
        }

        scheduleRestart()
    }

    /// Ensure the audio engine is running with a valid input tap. Returns `false` (without
    /// crashing) when the mic input format is invalid — `installTap` with a 0-channel /
    /// 0-Hz format raises an uncatchable Obj-C exception, so we guard against it explicitly.
    private func ensureEngineRunning() -> Bool {
        if engine.isRunning { return true }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            NSLog("[IRIS] mic not ready — input format \(format.sampleRate)Hz \(format.channelCount)ch; will retry")
            return false
        }

        input.removeTap(onBus: 0)   // safe even if no tap is installed; avoids double-tap crash
        input.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, _ in
            // Drop mic audio while IRIS is speaking so it never hears its own TTS.
            guard let self, !self.isMuted else { return }
            self.request?.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
            NSLog("[IRIS] audio engine started — \(format.sampleRate)Hz \(format.channelCount)ch; listening for '\(settings.wakePhrase)'")
            return true
        } catch {
            NSLog("[IRIS] audio engine failed to start: \(error.localizedDescription)")
            input.removeTap(onBus: 0)
            return false
        }
    }

    /// Retry bringing up the engine after a brief pause (mic not ready yet).
    private func scheduleEngineRetry() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.isRunning, !self.capturing else { return }
            self.startSession()
        }
    }

    /// Cancel the current recognition task/request and bump the generation so any late
    /// callbacks from the old session are ignored. Leaves the audio engine/tap running.
    private func teardownRecognition() {
        generation += 1
        restartTimer?.invalidate(); restartTimer = nil
        settleTimer?.invalidate(); settleTimer = nil
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
    }

    /// Fully stop recognition and the audio engine (frees the mic for `Transcriber`).
    private func stopSession() {
        teardownRecognition()
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    private func scheduleRestart() {
        restartTimer?.invalidate()
        restartTimer = Timer.scheduledTimer(withTimeInterval: restartInterval, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.isRunning, !self.capturing, !self.awaitingSettle else { return }
                self.startSession()
            }
        }
    }

    // MARK: - Wake handling

    private func handleTranscript(_ transcript: String) {
        guard !capturing else { return }
        NSLog("[IRIS] heard: \"\(transcript)\"")
        guard transcript.lowercased().contains(settings.wakePhrase) else { return }
        NSLog("[IRIS] wake phrase matched → arming command capture")

        if !awaitingSettle {
            awaitingSettle = true
            appState?.status = .listening
        }
        latestWakeTranscript = transcript
        resetSettleTimer()
    }

    private func resetSettleTimer() {
        settleTimer?.invalidate()
        settleTimer = Timer.scheduledTimer(withTimeInterval: settleTimeout, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.settleWakeUtterance() }
        }
    }

    private func settleWakeUtterance() {
        guard awaitingSettle, !capturing else { return }
        awaitingSettle = false

        let remainder = commandRemainder(from: latestWakeTranscript)
        if !remainder.isEmpty {
            deliver(remainder)             // command spoken in the same breath as the wake word
        } else {
            beginFreshCapture()            // "hey iris" then a pause → capture the command next
        }
    }

    private func beginFreshCapture() {
        capturing = true
        stopSession()                      // release the mic for the transcriber's own engine
        transcriber.start(
            onResult: { [weak self] text in
                guard let self else { return }
                self.capturing = false
                self.deliver(self.commandRemainder(from: text))
            },
            onError: { [weak self] _ in
                guard let self else { return }
                self.capturing = false
                self.deliver("")
            }
        )
    }

    private func deliver(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        // Stop listening while the brain works and IRIS speaks; we re-arm afterward.
        stopSession()
        if !trimmed.isEmpty {
            onWakeWordDetected?(trimmed)
        } else {
            appState?.status = .idle
        }
        scheduleRearm()
    }

    private func scheduleRearm() {
        DispatchQueue.main.asyncAfter(deadline: .now() + rearmDebounce) { [weak self] in
            guard let self, self.isRunning, !self.capturing else { return }
            self.startSession()
        }
    }

    // MARK: - Command extraction

    /// Everything after the wake phrase, trimmed. If the phrase isn't present, the whole
    /// (trimmed) string is returned — used defensively on freshly captured commands too.
    private func commandRemainder(from transcript: String) -> String {
        if let range = transcript.range(of: settings.wakePhrase, options: [.caseInsensitive]) {
            return String(transcript[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
