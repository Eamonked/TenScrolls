import Foundation

enum TimeUtils {
    /// Parse "HH:mm" into hour and minute. Returns nil if invalid.
    static func parseHHmm(_ string: String) -> (hour: Int, minute: Int)? {
        let parts = string.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0..<24).contains(hour), (0..<60).contains(minute) else {
            return nil
        }
        return (hour, minute)
    }

    /// Today's Date anchored at the given "HH:mm" time. If parsing fails, returns
    /// today at midnight (not `now`) — callers that need to detect a bad string
    /// should check `parseHHmm` themselves rather than relying on this fallback.
    static func dateFromHHmm(_ string: String, calendar: Calendar = .current) -> Date {
        let now = Date()
        var comps = calendar.dateComponents([.year, .month, .day], from: now)
        if let (h, m) = parseHHmm(string) {
            comps.hour = h
            comps.minute = m
            comps.second = 0
            return calendar.date(from: comps) ?? now
        } else {
            comps.hour = 0
            comps.minute = 0
            comps.second = 0
            return calendar.date(from: comps) ?? now
        }
    }

    /// "HH:mm" string from a Date's hour/minute in the current calendar.
    static func hhmm(from date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let h = c.hour ?? 0
        let m = c.minute ?? 0
        return String(format: "%02d:%02d", h, m)
    }
}
