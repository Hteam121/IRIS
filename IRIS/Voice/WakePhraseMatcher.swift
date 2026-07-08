//
//  WakePhraseMatcher.swift
//  IRIS — Voice + Audio lane
//
//  Matches the configured wake phrase in live transcripts. SFSpeechRecognizer frequently
//  mishears "Dory" (pronounced "dough-ree") — observed: "worried", "dori", "dora" — so when
//  the configured phrase is the default ("hey dory") a small set of known mishearings is
//  accepted too. Matching is punctuation/whitespace tolerant ("hey, worried" matches
//  "hey worried"). A custom phrase matches (tolerantly) as itself, no variants.
//  Variant list is tuned live — see docs/algorithms.md → wake word.
//

import Foundation

struct WakePhraseMatcher {
    /// Known SFSpeechRecognizer mishearings of the default "hey dory". Each variant also
    /// widens the barge-in trigger, so keep entries to observed mishearings — don't add
    /// sound-alikes that occur mid-sentence in normal dictation without live testing.
    static let defaultVariants = [
        "hey dory", "hey dori", "hey dorie", "hey dorey", "hey dora",
        "hey worried",          // most common mishearing of "dough-ree"
        "hey dore", "hey door e", "hey door he", "hey doree",
    ]

    /// Bare-name variants (jarvis-style: the name ANYWHERE in a sentence — "…, Dory?").
    /// Deliberately short: bare mishearings like "worried" fire far too often mid-sentence.
    static let bareNameVariants = ["dory", "dori", "dorie"]

    /// One tolerant regex per accepted phrase: words joined by any run of
    /// whitespace/punctuation, word-bounded at both ends, case-insensitive.
    private let regexes: [NSRegularExpression]

    init(configured: String, includeBareName: Bool = false) {
        var phrases = (configured.lowercased() == Settings.defaultWakePhrase)
            ? Self.defaultVariants : [configured.lowercased()]
        if includeBareName, configured.lowercased() == Settings.defaultWakePhrase {
            phrases += Self.bareNameVariants
        }
        regexes = phrases.compactMap { phrase in
            let words = phrase
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map { NSRegularExpression.escapedPattern(for: String($0)) }
            guard !words.isEmpty else { return nil }
            let pattern = "\\b" + words.joined(separator: "[\\s\\p{P}]+") + "\\b"
            return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        }
    }

    /// Whether the transcript contains any accepted wake phrase.
    func matches(_ transcript: String) -> Bool {
        earliestRange(in: transcript) != nil
    }

    /// Earliest occurrence of any accepted phrase.
    func earliestRange(in s: String) -> Range<String.Index>? {
        let full = NSRange(s.startIndex..., in: s)
        var best: Range<String.Index>?
        for regex in regexes {
            guard let m = regex.firstMatch(in: s, range: full),
                  let r = Range(m.range, in: s) else { continue }
            if best == nil || r.lowerBound < best!.lowerBound { best = r }
        }
        return best
    }

    /// Everything after the first wake phrase, trimmed. If no phrase is present, the whole
    /// (trimmed) string is returned — used defensively on freshly captured commands too.
    func commandRemainder(from transcript: String) -> String {
        guard let r = earliestRange(in: transcript) else {
            return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(transcript[r.upperBound...])
            .trimmingCharacters(in: CharacterSet.punctuationCharacters
                .union(.whitespacesAndNewlines))
    }

    /// The command around the first wake phrase: (before, after), both trimmed. With bare-name
    /// waking the command often PRECEDES the name ("can you check that, Dory?") — the caller
    /// prefers `after` and falls back to `before`.
    func commandParts(from transcript: String) -> (before: String, after: String) {
        guard let r = earliestRange(in: transcript) else {
            return ("", transcript.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let strip = CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines)
        return (String(transcript[..<r.lowerBound]).trimmingCharacters(in: strip),
                String(transcript[r.upperBound...]).trimmingCharacters(in: strip))
    }

    /// Split a command string on any (additional) occurrences of the wake phrase, returning the
    /// non-empty segments in order. "what's on my screen hey dory what time is it" →
    /// ["what's on my screen", "what time is it"]. A string with no wake phrase yields itself.
    func splitOnWakePhrase(_ command: String) -> [String] {
        var segments: [String] = []
        var remaining = command
        while let r = earliestRange(in: remaining) {
            let before = String(remaining[..<r.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !before.isEmpty { segments.append(before) }
            remaining = String(remaining[r.upperBound...])
        }
        let tail = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { segments.append(tail) }
        return segments
    }
}
