import Foundation
import AppKit

// MARK: - Data Model

enum BlockState: String, Codable {
    case active      // Overlay shown, user blocked
    case snoozed     // User postponed, overlay hidden temporarily
    case sleeping    // System sleep during block
    case ended       // Session closed
}

enum EndReason: String, Codable {
    case completed   // Natural end of block
    case exited      // User manually exited early
    case cancelled   // Block cancelled (e.g., schedule disabled)
    case error       // Recovered from crash/abnormal termination
}

struct BlockEvent: Codable, Identifiable {
    var id: UUID
    var timestamp: Date
    var state: BlockState
    var endReason: EndReason?  // Only meaningful when state == .ended

    init(state: BlockState, endReason: EndReason? = nil) {
        self.id = UUID()
        self.timestamp = Date()
        self.state = state
        self.endReason = endReason
    }
}

struct BlockSession: Codable, Identifiable {
    var id: UUID
    var scheduleName: String
    var scheduleID: UUID?
    var createdAt: Date
    var lastUpdatedAt: Date
    var events: [BlockEvent]

    init(scheduleName: String, scheduleID: UUID?) {
        self.id = UUID()
        self.scheduleName = scheduleName
        self.scheduleID = scheduleID
        self.createdAt = Date()
        self.lastUpdatedAt = Date()
        self.events = [BlockEvent(state: .active)]
    }

    var currentState: BlockState {
        events.last?.state ?? .ended
    }

    var isOpen: Bool {
        currentState != .ended
    }

    var endReason: EndReason? {
        events.last(where: { $0.state == .ended })?.endReason
    }

    mutating func appendEvent(_ event: BlockEvent) {
        events.append(event)
        lastUpdatedAt = event.timestamp
    }
}

struct BlockTotals {
    var active: TimeInterval = 0
    var snoozed: TimeInterval = 0
    var sleeping: TimeInterval = 0

    var total: TimeInterval {
        active + snoozed + sleeping
    }
}

// MARK: - Stats Manager

class StatsManager {
    static let shared = StatsManager()

    private var currentSession: BlockSession?
    private var stateBeforeSleep: BlockState?  // Track state before sleep for proper restoration
    private let statsDirectory: URL

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        statsDirectory = appSupport.appendingPathComponent("ScreenBlocker/Stats", isDirectory: true)

        try? FileManager.default.createDirectory(at: statsDirectory, withIntermediateDirectories: true)

        recoverIfNeeded()
    }

    // MARK: - Session Lifecycle

    /// Start a new blocking session. Returns session ID.
    @discardableResult
    func startSession(scheduleName: String, scheduleID: UUID?) -> UUID {
        // Only start if no active session
        guard currentSession == nil else {
            return currentSession!.id
        }

        let session = BlockSession(scheduleName: scheduleName, scheduleID: scheduleID)
        currentSession = session
        saveCurrentSession()
        return session.id
    }

    /// End the current session with a reason.
    func endSession(reason: EndReason) {
        guard var session = currentSession, session.isOpen else { return }

        session.appendEvent(BlockEvent(state: .ended, endReason: reason))
        saveSession(session)
        currentSession = nil
    }

    // MARK: - State Transitions

    /// Pause for user-initiated snooze. Only valid when active.
    func pauseForSnooze() {
        guard var session = currentSession, session.currentState == .active else { return }

        session.appendEvent(BlockEvent(state: .snoozed))
        currentSession = session
        saveCurrentSession()
    }

    /// Resume from snooze. Only valid when snoozed.
    func resumeFromSnooze() {
        guard var session = currentSession, session.currentState == .snoozed else { return }

        session.appendEvent(BlockEvent(state: .active))
        currentSession = session
        saveCurrentSession()
    }

    /// Pause for system sleep. Valid when active or snoozed.
    func pauseForSleep() {
        guard var session = currentSession,
              session.currentState == .active || session.currentState == .snoozed else { return }

        // Remember the state before sleep so we can restore it
        stateBeforeSleep = session.currentState

        session.appendEvent(BlockEvent(state: .sleeping))
        currentSession = session
        saveCurrentSession()
    }

    /// Resume from system sleep to the specified state. Only valid when sleeping.
    /// If no state specified, restores to the state before sleep (default: active).
    func resumeFromSleep(to targetState: BlockState? = nil) {
        guard var session = currentSession, session.currentState == .sleeping else { return }

        let resumeState = targetState ?? stateBeforeSleep ?? .active
        stateBeforeSleep = nil

        session.appendEvent(BlockEvent(state: resumeState))
        currentSession = session
        saveCurrentSession()
    }

    // MARK: - Recovery

    /// Check for orphaned sessions on startup and close them.
    private func recoverIfNeeded() {
        // Load sessions from current and previous month to find any open ones
        let now = Date()
        let calendar = Calendar.current

        var sessionsToCheck: [BlockSession] = []
        sessionsToCheck.append(contentsOf: loadSessions(from: fileURL(for: now)))

        if let lastMonth = calendar.date(byAdding: .month, value: -1, to: now) {
            sessionsToCheck.append(contentsOf: loadSessions(from: fileURL(for: lastMonth)))
        }

        // Find any open sessions and close them with error
        for var session in sessionsToCheck where session.isOpen {
            session.appendEvent(BlockEvent(state: .ended, endReason: .error))
            saveSession(session)
        }
    }

    // MARK: - Persistence

    private func fileURL(for date: Date) -> URL {
        let filename = Self.monthFormatter.string(from: date) + ".json"
        return statsDirectory.appendingPathComponent(filename)
    }

    private func saveCurrentSession() {
        guard let session = currentSession else { return }
        saveSession(session)
    }

    private func saveSession(_ session: BlockSession) {
        let url = fileURL(for: session.createdAt)
        var sessions = loadSessions(from: url)

        // Update existing or append new
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }

        do {
            let data = try JSONEncoder().encode(sessions)
            try data.write(to: url, options: .atomic)
        } catch {
            print("Failed to save session: \(error)")
        }
    }

    private func loadSessions(from url: URL) -> [BlockSession] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([BlockSession].self, from: data)
        } catch {
            print("Failed to load sessions from \(url.lastPathComponent): \(error)")
            return []
        }
    }

    // MARK: - Querying

    func sessions(for period: StatsPeriod, offset: Int = 0) -> [BlockSession] {
        let calendar = Calendar.current
        let now = Date()
        let (startDate, endDate) = period.dateRange(from: now, offset: offset)

        var allSessions: [BlockSession] = []

        // Load from relevant months (include previous month to catch spanning sessions)
        var checkDate = calendar.date(byAdding: .month, value: -1, to: startDate) ?? startDate
        while checkDate <= endDate {
            let url = fileURL(for: checkDate)
            allSessions.append(contentsOf: loadSessions(from: url))

            guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: checkDate) else { break }
            checkDate = calendar.date(from: calendar.dateComponents([.year, .month], from: nextMonth)) ?? nextMonth
        }

        // Filter to sessions that overlap with the period
        return allSessions.filter { session in
            let sessionEnd = session.events.last?.timestamp ?? session.createdAt
            return sessionEnd > startDate && session.createdAt < endDate
        }
    }

    func totals(for period: StatsPeriod, offset: Int = 0) -> BlockTotals {
        let (startDate, endDate) = period.dateRange(from: Date(), offset: offset)
        let sessions = sessions(for: period, offset: offset)

        var totals = BlockTotals()

        for session in sessions {
            let sessionTotals = calculateTotals(for: session, clampedTo: startDate...endDate)
            totals.active += sessionTotals.active
            totals.snoozed += sessionTotals.snoozed
            totals.sleeping += sessionTotals.sleeping
        }

        return totals
    }

    /// Calculate totals for a single session, optionally clamped to a date range.
    private func calculateTotals(for session: BlockSession, clampedTo range: ClosedRange<Date>? = nil) -> BlockTotals {
        var totals = BlockTotals()

        let events = session.events
        guard !events.isEmpty else { return totals }

        for i in 0..<events.count {
            let event = events[i]
            let nextTimestamp: Date

            if i + 1 < events.count {
                nextTimestamp = events[i + 1].timestamp
            } else if event.state != .ended {
                // Open session - use current time
                nextTimestamp = Date()
            } else {
                // Ended session - no duration to add for the end event
                continue
            }

            // Clamp to range if provided
            var start = event.timestamp
            var end = nextTimestamp

            if let range = range {
                start = max(start, range.lowerBound)
                end = min(end, range.upperBound)
            }

            let duration = max(0, end.timeIntervalSince(start))

            switch event.state {
            case .active:
                totals.active += duration
            case .snoozed:
                totals.snoozed += duration
            case .sleeping:
                totals.sleeping += duration
            case .ended:
                break
            }
        }

        return totals
    }

    // MARK: - Helpers

    var hasActiveSession: Bool {
        currentSession?.isOpen ?? false
    }

    var activeSessionScheduleName: String? {
        currentSession?.scheduleName
    }
}

// MARK: - Stats Period

enum StatsPeriod: String, CaseIterable {
    case day = "Day"
    case week = "Week"
    case month = "Month"
    case year = "Year"

    func dateRange(from referenceDate: Date, offset: Int) -> (start: Date, end: Date) {
        let calendar = Calendar.current

        switch self {
        case .day:
            guard let targetDate = calendar.date(byAdding: .day, value: offset, to: referenceDate),
                  let start = calendar.startOfDay(for: targetDate) as Date?,
                  let end = calendar.date(byAdding: .day, value: 1, to: start) else {
                return (referenceDate, referenceDate)
            }
            return (start, end)

        case .week:
            guard let targetDate = calendar.date(byAdding: .weekOfYear, value: offset, to: referenceDate),
                  let weekInterval = calendar.dateInterval(of: .weekOfYear, for: targetDate) else {
                return (referenceDate, referenceDate)
            }
            return (weekInterval.start, weekInterval.end)

        case .month:
            guard let targetDate = calendar.date(byAdding: .month, value: offset, to: referenceDate),
                  let monthInterval = calendar.dateInterval(of: .month, for: targetDate) else {
                return (referenceDate, referenceDate)
            }
            return (monthInterval.start, monthInterval.end)

        case .year:
            guard let targetDate = calendar.date(byAdding: .year, value: offset, to: referenceDate),
                  let yearInterval = calendar.dateInterval(of: .year, for: targetDate) else {
                return (referenceDate, referenceDate)
            }
            return (yearInterval.start, yearInterval.end)
        }
    }

    func formatLabel(for referenceDate: Date, offset: Int) -> String {
        let calendar = Calendar.current
        let (start, end) = dateRange(from: referenceDate, offset: offset)

        let formatter = DateFormatter()

        switch self {
        case .day:
            if offset == 0 {
                return "Today"
            } else if offset == -1 {
                return "Yesterday"
            }
            formatter.dateStyle = .medium
            return formatter.string(from: start)

        case .week:
            if offset == 0 {
                return "This Week"
            }
            formatter.dateFormat = "MMM d"
            let startStr = formatter.string(from: start)
            let endDate = calendar.date(byAdding: .day, value: -1, to: end) ?? end
            let endStr = formatter.string(from: endDate)
            return "\(startStr) – \(endStr)"

        case .month:
            if offset == 0 {
                return "This Month"
            }
            formatter.dateFormat = "MMMM yyyy"
            return formatter.string(from: start)

        case .year:
            if offset == 0 {
                return "This Year"
            }
            formatter.dateFormat = "yyyy"
            return formatter.string(from: start)
        }
    }
}
