//
//  CostGovernor.swift
//  IRIS — Core (cost control)
//
//  Meters real OpenAI spend and adapts IRIS's behavior to stay within a user-set monthly
//  budget. Realtime cost is computed EXACTLY from the token `usage` the Realtime API returns
//  on each `response.done`; TTS cost is estimated from characters synthesized. Spend is
//  persisted to ~/.iris/usage.json and rolls over each calendar month.
//
//  The governor exposes a `tier()` the rest of the app checks at each interaction:
//    • .premium → realtime (gpt-realtime-mini) conversation mode allowed — best experience.
//    • .saver   → classic `claude -p` pipeline (free brain) default; realtime suppressed.
//    • .free    → budget exhausted: `claude -p` brain + on-device TTS only (zero OpenAI spend).
//
//  Pacing (docs/algorithms.md → Cost Governor): besides the spent-fraction tiers, a daily
//  allowance (remaining ÷ days-left-in-month) throttles back to .saver once today's fair
//  share is used, so a single binge can't drain the whole month on day one.
//

import Foundation

/// How constrained IRIS should be given the remaining monthly budget.
public enum CostTier: String, Sendable {
    case premium   // realtime conversation mode allowed
    case saver     // classic claude -p pipeline default; realtime suppressed
    case free      // budget spent: claude -p brain + on-device TTS only
}

@MainActor
public final class CostGovernor {

    /// OpenAI rates in USD per 1,000,000 tokens. See docs/algorithms.md → Cost Governor.
    struct RealtimeRates {
        let audioIn: Double, audioInCached: Double, audioOut: Double
        let textIn: Double, textInCached: Double, textOut: Double
    }
    /// gpt-realtime-mini (gpt-4o-mini-realtime): the cost-optimized default.
    static let miniRates = RealtimeRates(
        audioIn: 10, audioInCached: 0.30, audioOut: 20, textIn: 0.60, textInCached: 0.30, textOut: 2.40)
    /// gpt-realtime (full GA model): ~3.2× the mini audio rates.
    static let fullRates = RealtimeRates(
        audioIn: 32, audioInCached: 0.40, audioOut: 64, textIn: 4, textInCached: 0.40, textOut: 16)
    /// gpt-4o-mini-tts ≈ $15 per 1M input characters (token-based; this is the documented estimate).
    static let ttsCostPerChar = 15.0 / 1_000_000.0
    /// gpt-4o (vision + function-calling) text rates, USD per 1,000,000 tokens. Used to meter the
    /// one-shot paid calls — screen-rule vision match, screen vision, OpenAI command classifier.
    static let visionInputRate = 2.50
    static let visionOutputRate = 10.0
    /// Fallback per-call estimate (~one screenshot vision call) when a response omits `usage`, so a
    /// paid call is never recorded as zero spend.
    static let visionFlatEstimateUSD = 0.005

    // Tier thresholds (docs/algorithms.md → Cost Governor).
    private static let saverFraction = 0.75    // ≥75% of budget spent → saver
    private static let freeFloorUSD = 0.01     // ≤1¢ remaining → free

    private(set) var budgetUSD: Double         // 0 (or negative) ⇒ unlimited
    private var realtimeModelIsMini: Bool

    // Persisted spend state (~/.iris/usage.json).
    private var month: String                  // "yyyy-MM"
    private var day: String                    // "yyyy-MM-dd"
    private var spentUSD: Double
    private var spentTodayUSD: Double

    private let fileURL: URL

    public init(budgetUSD: Double, realtimeModel: String) {
        self.budgetUSD = budgetUSD
        self.realtimeModelIsMini = realtimeModel.lowercased().contains("mini")
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".iris", isDirectory: true)
        self.fileURL = dir.appendingPathComponent("usage.json")
        self.month = Self.currentMonth()
        self.day = Self.currentDay()
        self.spentUSD = 0
        self.spentTodayUSD = 0
        load()
    }

    // MARK: - Live config

    public func applyBudget(_ usd: Double) { budgetUSD = max(0, usd) }
    public func applyRealtimeModel(_ model: String) {
        realtimeModelIsMini = model.lowercased().contains("mini")
    }

    // MARK: - Metering

    /// Record one realtime turn's spend from the `usage` object in a `response.done` event.
    public func recordRealtime(usage: [String: Any]) {
        let rates = realtimeModelIsMini ? Self.miniRates : Self.fullRates
        let inDet = usage["input_token_details"] as? [String: Any] ?? [:]
        let outDet = usage["output_token_details"] as? [String: Any] ?? [:]

        let totalAudioIn = intOf(inDet["audio_tokens"])
        let totalTextIn = intOf(inDet["text_tokens"])

        var cachedAudioIn = 0, cachedTextIn = 0
        if let cached = inDet["cached_tokens_details"] as? [String: Any] {
            cachedAudioIn = intOf(cached["audio_tokens"])
            cachedTextIn = intOf(cached["text_tokens"])
        } else {
            // Older shape: a flat `cached_tokens`. Attribute to audio (the dominant input).
            cachedAudioIn = min(totalAudioIn, intOf(inDet["cached_tokens"]))
        }

        let uncachedAudioIn = max(0, totalAudioIn - cachedAudioIn)
        let uncachedTextIn = max(0, totalTextIn - cachedTextIn)
        let audioOut = intOf(outDet["audio_tokens"])
        let textOut = intOf(outDet["text_tokens"])

        let cost = (Double(uncachedAudioIn) * rates.audioIn
            + Double(cachedAudioIn) * rates.audioInCached
            + Double(uncachedTextIn) * rates.textIn
            + Double(cachedTextIn) * rates.textInCached
            + Double(audioOut) * rates.audioOut
            + Double(textOut) * rates.textOut) / 1_000_000.0
        add(cost)
    }

    /// Record a neural-TTS synthesis (estimated from character count).
    public func recordTTS(characters: Int) {
        guard characters > 0 else { return }
        add(Double(characters) * Self.ttsCostPerChar)
    }

    /// Record one paid gpt-4o call (screen-rule match, screen vision, or OpenAI command
    /// classifier) from the `usage` object the chat-completions API returns. Falls back to a small
    /// flat estimate when `usage` is absent so the spend is never silently dropped.
    public func recordVision(usage: [String: Any]?) {
        let inTok = intOf(usage?["prompt_tokens"])
        let outTok = intOf(usage?["completion_tokens"])
        let cost = (inTok > 0 || outTok > 0)
            ? (Double(inTok) * Self.visionInputRate + Double(outTok) * Self.visionOutputRate) / 1_000_000.0
            : Self.visionFlatEstimateUSD
        add(cost)
    }

    // MARK: - Policy

    public var spent: Double { rollOverIfNeeded(); return spentUSD }
    public var remaining: Double {
        guard budgetUSD > 0 else { return .infinity }
        return max(0, budgetUSD - spent)
    }

    /// The current behavior tier given remaining budget and today's pace.
    public func tier(now: Date = Date()) -> CostTier {
        guard budgetUSD > 0 else { return .premium }   // unlimited
        rollOverIfNeeded(now: now)
        let rem = max(0, budgetUSD - spentUSD)
        if rem <= Self.freeFloorUSD { return .free }
        if spentUSD / budgetUSD >= Self.saverFraction { return .saver }
        // Daily pacing: once today's fair share is spent, fall back to the free pipeline
        // for the rest of the day so the month can't be drained early.
        let dailyAllowance = rem / Double(max(1, Self.daysLeftInMonth(now)))
        if spentTodayUSD >= dailyAllowance { return .saver }
        return .premium
    }

    /// Whether the paid realtime conversation core may run right now.
    public var allowsRealtime: Bool { tier() == .premium }
    /// Whether neural (OpenAI) TTS may be used right now (else on-device).
    public var allowsNeuralTTS: Bool { tier() != .free }
    /// Whether a paid one-shot OpenAI call (screen-rule vision match, screen vision, OpenAI command
    /// classifier) may run now. False once the budget is spent (`.free`), preserving that tier's
    /// documented "zero OpenAI spend" guarantee.
    public var allowsPaidVision: Bool { tier() != .free }

    // MARK: - Internals

    private func add(_ cost: Double) {
        guard cost > 0 else { return }
        rollOverIfNeeded()
        spentUSD += cost
        spentTodayUSD += cost
        schedulePersist()
    }

    private func rollOverIfNeeded(now: Date = Date()) {
        let m = Self.currentMonth(now), d = Self.currentDay(now)
        var changed = false
        if m != month { month = m; spentUSD = 0; spentTodayUSD = 0; day = d; changed = true }
        if d != day { day = d; spentTodayUSD = 0; changed = true }
        if changed { writeUsageFile() }   // a rollover is rare and important → persist immediately
    }

    // MARK: - Persistence (debounced)

    /// Debounce window for hot-path writes (docs/algorithms.md → Cost Governor).
    private static let persistDebounceNs: UInt64 = 1_500_000_000
    private var persistScheduled = false

    /// Coalesce hot-path writes: rather than rewriting usage.json on every realtime turn / TTS
    /// utterance, schedule a single write shortly after the last metered event.
    private func schedulePersist() {
        guard !persistScheduled else { return }
        persistScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.persistDebounceNs)
            guard let self else { return }
            self.persistScheduled = false
            self.writeUsageFile()
        }
    }

    /// Persist immediately, bypassing the debounce — call on app termination so the last turns'
    /// spend is never lost.
    public func flush() {
        persistScheduled = false
        writeUsageFile()
    }

    private func intOf(_ any: Any?) -> Int {
        if let n = any as? Int { return n }
        if let n = any as? NSNumber { return n.intValue }
        if let d = any as? Double { return Int(d) }
        return 0
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        let storedMonth = obj["month"] as? String ?? month
        let storedDay = obj["day"] as? String ?? day
        // Honor monthly/daily rollover at load time too.
        if storedMonth == Self.currentMonth() {
            spentUSD = (obj["spentUSD"] as? NSNumber)?.doubleValue ?? 0
            month = storedMonth
            if storedDay == Self.currentDay() {
                spentTodayUSD = (obj["spentTodayUSD"] as? NSNumber)?.doubleValue ?? 0
                day = storedDay
            }
        }
    }

    private func writeUsageFile() {
        let obj: [String: Any] = [
            "month": month, "day": day,
            "spentUSD": spentUSD, "spentTodayUSD": spentTodayUSD,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) else { return }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func currentMonth(_ now: Date = Date()) -> String { stamp(now, "yyyy-MM") }
    private static func currentDay(_ now: Date = Date()) -> String { stamp(now, "yyyy-MM-dd") }
    private static func stamp(_ date: Date, _ format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f.string(from: date)
    }

    /// Days remaining in the current month, inclusive of today (≥ 1).
    private static func daysLeftInMonth(_ now: Date = Date()) -> Int {
        let cal = Calendar.current
        guard let range = cal.range(of: .day, in: .month, for: now) else { return 1 }
        let today = cal.component(.day, from: now)
        return max(1, range.count - today + 1)
    }
}
