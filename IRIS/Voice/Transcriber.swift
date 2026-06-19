//
//  Transcriber.swift
//  IRIS — Voice + Audio lane (Phase 1)
//
//  A one-shot spoken-command capturer built on AVAudioEngine + SFSpeechRecognizer.
//  `WakeWordDetector` uses this for the "hey iris" → [pause] → command case, where the
//  command arrives in a fresh utterance after the wake phrase. It captures a single
//  utterance and returns the trimmed transcript when the speaker pauses (silence) or the
//  hard max-duration elapses.
//
//  Lane B owns this file; it depends only on the frozen Phase 0 contract (`Settings`).
//

import Foundation
import AVFoundation
import Speech

enum TranscriberError: Error {
    case recognizerUnavailable
}

@MainActor
final class Transcriber: NSObject {
    private let recognizer: SFSpeechRecognizer?
    private let engine = AVAudioEngine()

    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    private var onResult: ((String) -> Void)?
    private var onError: ((Error) -> Void)?

    private var silenceTimer: Timer?
    private var maxDurationTimer: Timer?
    private var latestTranscript = ""
    private var finished = false

    // Tuned constants — see docs/algorithms.md → "Command capture (Transcriber)".
    private let bufferSize: AVAudioFrameCount = 1024
    private let silenceTimeout: TimeInterval = 1.5   // finalize after this much quiet
    private let maxDuration: TimeInterval = 12.0     // hard stop so we never hang open

    init(settings: Settings) {
        let locale = Locale(identifier: settings.voice)
        self.recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
        super.init()
    }

    /// Capture a single utterance. `onResult` fires with the trimmed transcript once the
    /// speaker pauses (or `maxDuration` elapses); `onError` fires if the recognizer can't start.
    func start(onResult: @escaping (String) -> Void, onError: @escaping (Error) -> Void) {
        // Reset any prior capture without firing callbacks.
        cancel()
        finished = false
        latestTranscript = ""
        self.onResult = onResult
        self.onError = onError

        guard let recognizer, recognizer.isAvailable else {
            fail(TranscriberError.recognizerUnavailable)
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // `installTap` with a 0-channel / 0-Hz format raises an uncatchable Obj-C exception
        // (mic not ready / mid-handoff). Guard rather than crash.
        guard format.channelCount > 0, format.sampleRate > 0 else {
            NSLog("[IRIS] Transcriber: mic not ready — input format \(format.sampleRate)Hz \(format.channelCount)ch")
            fail(TranscriberError.recognizerUnavailable)
            return
        }

        input.removeTap(onBus: 0)   // safe even if none installed
        input.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            fail(error)
            return
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let result {
                    self.latestTranscript = result.bestTranscription.formattedString
                    self.resetSilenceTimer()
                    if result.isFinal { self.finish() }
                }
                // An error here just means the session ended; finalize with what we have.
                if error != nil { self.finish() }
            }
        }

        startMaxDurationTimer()
    }

    /// Abort capture without delivering a result (used to reset state before a new start).
    func cancel() {
        finished = true
        teardownAudio()
        onResult = nil
        onError = nil
    }

    // MARK: - Finalization

    private func finish() {
        guard !finished else { return }
        finished = true
        let text = latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let callback = onResult
        teardownAudio()
        onResult = nil
        onError = nil
        callback?(text)
    }

    private func fail(_ error: Error) {
        guard !finished else { return }
        finished = true
        let callback = onError
        teardownAudio()
        onResult = nil
        onError = nil
        callback?(error)
    }

    private func teardownAudio() {
        silenceTimer?.invalidate(); silenceTimer = nil
        maxDurationTimer?.invalidate(); maxDurationTimer = nil
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    // MARK: - Timers

    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceTimeout, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.finish() }
        }
    }

    private func startMaxDurationTimer() {
        maxDurationTimer?.invalidate()
        maxDurationTimer = Timer.scheduledTimer(withTimeInterval: maxDuration, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.finish() }
        }
    }
}
