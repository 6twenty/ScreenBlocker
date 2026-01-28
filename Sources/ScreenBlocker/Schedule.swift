import Foundation

struct Schedule: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var name: String
    var startHour: Int
    var startMinute: Int
    var endHour: Int
    var endMinute: Int
    var enabledDays: Set<Weekday>
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        name: String = "New Block",
        startHour: Int = 9,
        startMinute: Int = 0,
        endHour: Int = 9,
        endMinute: Int = 30,
        enabledDays: Set<Weekday> = Set(Weekday.allCases),
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.startHour = startHour
        self.startMinute = startMinute
        self.endHour = endHour
        self.endMinute = endMinute
        self.enabledDays = enabledDays
        self.isEnabled = isEnabled
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
    func isActive(at date: Date = Date()) -> Bool {
        guard isEnabled else { return false }

        let calendar = Calendar.current
        let weekday = Weekday.from(date: date)

        guard enabledDays.contains(weekday) else { return false }

        let components = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = components.hour, let minute = components.minute else { return false }

        let currentMinutes = hour * 60 + minute
        let startMinutes = startHour * 60 + startMinute
        let endMinutes = endHour * 60 + endMinute

        return currentMinutes >= startMinutes && currentMinutes < endMinutes
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

    var shortName: String {
        switch self {
        case .sunday: return "Sun"
        case .monday: return "Mon"
        case .tuesday: return "Tue"
        case .wednesday: return "Wed"
        case .thursday: return "Thu"
        case .friday: return "Fri"
        case .saturday: return "Sat"
        }
    }

    var initial: String {
        switch self {
        case .sunday: return "S"
        case .monday: return "M"
        case .tuesday: return "T"
        case .wednesday: return "W"
        case .thursday: return "T"
        case .friday: return "F"
        case .saturday: return "S"
        }
    }

    static func from(date: Date) -> Weekday {
        let calendar = Calendar.current
        let weekdayNumber = calendar.component(.weekday, from: date)
        return Weekday(rawValue: weekdayNumber) ?? .sunday
    }
}
