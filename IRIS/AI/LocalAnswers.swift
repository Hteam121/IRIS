//
//  LocalAnswers.swift
//  IRIS — Vision + AI lane
//
//  Instant, correct answers for things the Mac already knows (the time, the date) — answered
//  locally with no LLM round-trip. This also avoids the model replying that it "can't access
//  the clock", which it did for "what time is it".
//

import Foundation

enum LocalAnswers {
    /// Return a spoken answer for a local-info question (time/date), or nil if it isn't one.
    static func answer(for transcript: String) -> String? {
        let l = transcript.lowercased()

        let asksTime = l.contains("what time") || l.contains("the time")
            || l.contains("current time") || (l.contains("time") && l.contains("right now"))
        let asksDate = l.contains("what day") || l.contains("what's the date")
            || l.contains("whats the date") || l.contains("what is the date")
            || l.contains("what date") || l.contains("today's date") || l.contains("todays date")
            || l.contains("what's today") || l.contains("what is today")

        guard asksTime || asksDate else { return nil }

        let now = Date()
        let timeFmt = DateFormatter()
        timeFmt.timeStyle = .short
        timeFmt.dateStyle = .none
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "EEEE, MMMM d"

        switch (asksTime, asksDate) {
        case (true, false):
            return "It's \(timeFmt.string(from: now))."
        case (false, true):
            return "Today is \(dateFmt.string(from: now))."
        default:
            return "It's \(timeFmt.string(from: now)) on \(dateFmt.string(from: now))."
        }
    }
}
