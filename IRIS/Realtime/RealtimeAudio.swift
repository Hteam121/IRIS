//
//  RealtimeAudio.swift
//  IRIS — Realtime lane
//
//  One AVAudioEngine for the realtime voice loop:
//   • mic input → 24 kHz mono PCM16 for upstream (Realtime API format)
//   • model audio (24 kHz mono PCM16) → played through an AVAudioPlayerNode
//
//  We try to enable the input node's voice-processing (acoustic echo cancellation) so IRIS's own
//  output is removed from the mic — that's full-duplex barge-in with no self-hearing. If AEC won't
//  start or starves the input (a known macOS failure mode), we fall back to a plain engine and the
//  session gates the mic while IRIS is speaking (half-duplex) to avoid an echo loop.
//
//  To avoid format-not-supported (-10875) errors, the player is connected using the engine's OWN
//  output format and incoming 24 kHz audio is converted to it.
//
//  NOT @MainActor: the input tap fires on a realtime audio thread; state is configured before the
//  tap is installed and only read afterward. Marked @unchecked Sendable.
//

import Foundation
import AVFoundation

final class RealtimeAudio: @unchecked Sendable {
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var micConverter: AVAudioConverter?
    private var playConverter: AVAudioConverter?
    private var engineFormat: AVAudioFormat?   // the player↔mixer connection format

    /// Upstream target: 24 kHz mono PCM16.
    private let micFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true)!
    /// Incoming model audio decoded to float before conversion to the engine format.
    private let playSrcFormat = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!

    var onMicPCM16: ((Data) -> Void)?

    private(set) var isRunning = false
    private(set) var aecActive = false

    // Tracks ACTUAL speaker playback (queued buffers + a short decay grace) so the mic can be
    // muted in half-duplex mode until IRIS's own voice has fully stopped coming out of the
    // speaker — keying mute on the WebSocket "response.done" event left a tail that the mic heard,
    // causing IRIS to interrupt itself in a loop.
    private let playLock = NSLock()
    private var pendingBuffers = 0
    private var lastOutputAt = Date.distantPast
    private let outputGrace: TimeInterval = 0.6

    /// True while model audio is actually playing (or within the decay grace just after).
    var isOutputting: Bool {
        playLock.lock(); defer { playLock.unlock() }
        return pendingBuffers > 0 || Date().timeIntervalSince(lastOutputAt) < outputGrace
    }

    private let countLock = NSLock()
    private var bufferCount = 0
    private var bufferCountValue: Int { countLock.lock(); defer { countLock.unlock() }; return bufferCount }

    // MARK: - Lifecycle

    func start(preferAEC: Bool) throws {
        if preferAEC {
            do {
                try startEngine(voiceProcessing: true)
            } catch {
                IRISLog.log("realtime audio: AEC start failed (\(error.localizedDescription)) — using plain engine")
                rebuild()
                try startEngine(voiceProcessing: false)
            }
            // Watchdog: AEC can start but deliver no/low input — fall back to plain engine.
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.isRunning, self.aecActive, self.bufferCountValue < 3 else { return }
                IRISLog.log("realtime audio: AEC starved input — falling back to no-AEC half-duplex")
                self.rebuild()
                try? self.startEngine(voiceProcessing: false)
            }
        } else {
            try startEngine(voiceProcessing: false)
        }
    }

    private func startEngine(voiceProcessing vp: Bool) throws {
        guard !isRunning else { return }
        let input = engine.inputNode

        if vp {
            try input.setVoiceProcessingEnabled(true)   // throws → caller retries without
            aecActive = true
        } else {
            try? input.setVoiceProcessingEnabled(false)
            aecActive = false
        }

        engine.attach(player)
        let mixer = engine.mainMixerNode
        let outFmt = mixer.outputFormat(forBus: 0)        // engine's native working format
        engineFormat = outFmt
        engine.connect(player, to: mixer, format: outFmt)
        playConverter = AVAudioConverter(from: playSrcFormat, to: outFmt)

        let hwFormat = input.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            throw NSError(domain: "IRIS.RealtimeAudio", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Microphone not ready"])
        }
        micConverter = AVAudioConverter(from: hwFormat, to: micFormat)

        input.installTap(onBus: 0, bufferSize: 2048, format: hwFormat) { [weak self] buffer, _ in
            self?.handleMicBuffer(buffer)
        }

        engine.prepare()
        try engine.start()
        player.play()
        isRunning = true
        IRISLog.log("realtime audio started — mic \(Int(hwFormat.sampleRate))Hz, out \(Int(outFmt.sampleRate))Hz \(outFmt.channelCount)ch, AEC=\(aecActive)")
    }

    /// Tear down the engine so we can rebuild fresh (used for the no-AEC fallback).
    private func rebuild() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        isRunning = false
        countLock.lock(); bufferCount = 0; countLock.unlock()
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        if engine.isRunning { engine.stop() }
        isRunning = false
        playLock.lock(); pendingBuffers = 0; lastOutputAt = .distantPast; playLock.unlock()
    }

    /// Barge-in: drop any queued/playing output immediately.
    func stopPlayback() {
        guard isRunning else { return }
        player.stop()
        playLock.lock(); pendingBuffers = 0; lastOutputAt = Date(); playLock.unlock()
        player.play()
    }

    /// Play a chunk of 24 kHz mono PCM16 audio from the model.
    func playPCM16(_ data: Data) {
        guard isRunning, let converted = makeOutputBuffer(from: data) else { return }
        playLock.lock(); pendingBuffers += 1; lastOutputAt = Date(); playLock.unlock()
        player.scheduleBuffer(converted, completionHandler: { [weak self] in
            guard let self else { return }
            self.playLock.lock()
            self.pendingBuffers = max(0, self.pendingBuffers - 1)
            self.lastOutputAt = Date()
            self.playLock.unlock()
        })
        if !player.isPlaying { player.play() }
    }

    // MARK: - Conversion

    private func handleMicBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let micConverter, let onMicPCM16 else { return }
        let ratio = micFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: micFormat, frameCapacity: capacity) else { return }

        var fed = false
        var err: NSError?
        let status = micConverter.convert(to: out, error: &err) { _, inStatus in
            if fed { inStatus.pointee = .noDataNow; return nil }
            fed = true
            inStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0, let ch = out.int16ChannelData else { return }

        countLock.lock(); bufferCount += 1; let n = bufferCount; countLock.unlock()
        if n == 1 { IRISLog.log("realtime audio: mic streaming (first buffer, AEC=\(aecActive))") }

        onMicPCM16(Data(bytes: ch[0], count: Int(out.frameLength) * MemoryLayout<Int16>.size))
    }

    /// 24 kHz Int16 → float 24 kHz → engine output format buffer.
    private func makeOutputBuffer(from data: Data) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
        guard frames > 0,
              let src = AVAudioPCMBuffer(pcmFormat: playSrcFormat, frameCapacity: frames),
              let dst = src.floatChannelData?[0] else { return nil }
        src.frameLength = frames
        data.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            for i in 0..<Int(frames) { dst[i] = Float(Int16(littleEndian: s[i])) / 32768.0 }
        }
        guard let playConverter, let outFmt = engineFormat else { return src }

        let ratio = outFmt.sampleRate / playSrcFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(frames) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: capacity) else { return src }
        var fed = false
        var err: NSError?
        let status = playConverter.convert(to: out, error: &err) { _, inStatus in
            if fed { inStatus.pointee = .noDataNow; return nil }
            fed = true; inStatus.pointee = .haveData; return src
        }
        return status == .error ? nil : out
    }
}
