import Foundation

struct Schedule: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var name: String
    var message: String
    var startHour: Int
    var startMinute: Int
    var endHour: Int
    var endMinute: Int
    var enabledDays: Set<Weekday>
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        name: String = "New Block",
        message: String = "",
        startHour: Int = 9,
        startMinute: Int = 0,
        endHour: Int = 9,
        endMinute: Int = 30,
        enabledDays: Set<Weekday> = Set(Weekday.allCases),
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.message = message
        self.startHour = startHour
        self.startMinute = startMinute
        self.endHour = endHour
        self.endMinute = endMinute
        self.enabledDays = enabledDays
        self.isEnabled = isEnabled
    }

    // Custom Decodable to handle missing 'message' field from older saved data
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
        startHour = try container.decode(Int.self, forKey: .startHour)
        startMinute = try container.decode(Int.self, forKey: .startMinute)
        endHour = try container.decode(Int.self, forKey: .endHour)
        endMinute = try container.decode(Int.self, forKey: .endMinute)
        enabledDays = try container.decode(Set<Weekday>.self, forKey: .enabledDays)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, message, startHour, startMinute, endHour, endMinute, enabledDays, isEnabled
    }

    /// Duration in minutes, handling overnight schedules correctly
    var durationMinutes: Int {
        let startMinutes = startHour * 60 + startMinute
        let endMinutes = endHour * 60 + endMinute

        if endMinutes > startMinutes {
            // Normal same-day schedule
            return endMinutes - startMinutes
        } else if endMinutes < startMinutes {
            // Overnight schedule (e.g., 22:00-02:00)
            return (24 * 60 - startMinutes) + endMinutes
        } else {
            // start == end: ambiguous, default to 30 minutes
            return 30
        }
    }

    var startTimeString: String {
        String(format: "%d:%02d", startHour, startMinute)
    }

    var endTimeString: String {
        String(format: "%d:%02d", endHour, endMinute)
    }

    /// Returns the next occurrence of this schedule's start time, or nil if not applicable today
    func nextStart(after date: Date = Date()) -> Date? {
        guard isEnabled else { return nil }

        let calendar = Calendar.current
        let weekday = Weekday.from(date: date)

        // Check if enabled for today
        guard enabledDays.contains(weekday) else {
            return nextStartOnFutureDay(after: date)
        }

        // Create today's start time
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = startHour
        components.minute = startMinute
        components.second = 0

        guard let todayStart = calendar.date(from: components) else { return nil }

        // If start time is in the future today, use it
        if todayStart > date {
            return todayStart
        }

        // Otherwise, find next enabled day
        return nextStartOnFutureDay(after: date)
    }

    private func nextStartOnFutureDay(after date: Date) -> Date? {
        let calendar = Calendar.current

        // Look ahead up to 7 days
        for dayOffset in 1...7 {
            guard let futureDate = calendar.date(byAdding: .day, value: dayOffset, to: date) else { continue }
            let weekday = Weekday.from(date: futureDate)

            if enabledDays.contains(weekday) {
                var components = calendar.dateComponents([.year, .month, .day], from: futureDate)
                components.hour = startHour
                components.minute = startMinute
                components.second = 0
                return calendar.date(from: components)
            }
        }

        return nil
    }

    /// Check if the schedule is currently active
    /// Handles overnight schedules (e.g., 22:00-02:00) where end time is before start time
    func isActive(at date: Date = Date()) -> Bool {
        guard isEnabled else { return false }

        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = components.hour, let minute = components.minute else { return false }

        let currentMinutes = hour * 60 + minute
        let startMinutes = startHour * 60 + startMinute
        let endMinutes = endHour * 60 + endMinute

        // Check if this is an overnight schedule (end time is before start time)
        let isOvernight = endMinutes <= startMinutes

        if isOvernight {
            // For overnight schedules, we need to check two cases:
            // 1. Current time is after start (same day as start) - check yesterday's weekday for the "start day"
            // 2. Current time is before end (next day after start) - check today's weekday against start day

            let todayWeekday = Weekday.from(date: date)
            let yesterdayWeekday = Weekday.from(date: calendar.date(byAdding: .day, value: -1, to: date) ?? date)

            if currentMinutes >= startMinutes {
                // We're in the "after start" portion - check if today is an enabled start day
                return enabledDays.contains(todayWeekday)
            } else if currentMinutes < endMinutes {
                // We're in the "before end" portion (early morning) - check if yesterday was an enabled start day
                return enabledDays.contains(yesterdayWeekday)
            }
            return false
        } else {
            // Normal same-day schedule
            let weekday = Weekday.from(date: date)
            guard enabledDays.contains(weekday) else { return false }
            return currentMinutes >= startMinutes && currentMinutes < endMinutes
        }
    }
}

enum Weekday: Int, Codable, CaseIterable, Comparable {
    case sunday = 1
    case monday = 2
    case tuesday = 3
    case wednesday = 4
    case thursday = 5
    case friday = 6
    case saturday = 7

    static func < (lhs: Weekday, rhs: Weekday) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Locale-aware short weekday name (e.g., "Mon", "Tue")
    var shortName: String {
        let symbols = Calendar.current.shortWeekdaySymbols
        return symbols[rawValue - 1]  // rawValue is 1-based, array is 0-based
    }

    /// Locale-aware very short weekday name (e.g., "M", "Tu")
    var veryShortName: String {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        return symbols[rawValue - 1]
    }

    static func from(date: Date) -> Weekday {
        let calendar = Calendar.current
        let weekdayNumber = calendar.component(.weekday, from: date)
        return Weekday(rawValue: weekdayNumber) ?? .sunday
    }
}
