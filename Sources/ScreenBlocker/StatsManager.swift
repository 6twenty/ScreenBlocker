import Foundation
import AppKit

enum BlockEndReason: String, Codable {
    case completed   // Natural end of block
    case postponed   // User clicked "5 More Minutes"
    case exited      // User manually exited early
}

struct BlockRecord: Codable, Identifiable {
    var id: UUID
    var scheduleName: String
    var start: Date
    var end: Date
    var reason: BlockEndReason

    var duration: TimeInterval {
        end.timeIntervalSince(start)
    }
}

class StatsManager {
    static let shared = StatsManager()

    private var currentRecord: BlockRecord?
    private var sleepOccurredDuringBlock = false

    private let statsDirectory: URL

    // Cached formatter for file naming (yyyy-MM)
    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()

    private init() {
        // Store stats in Application Support
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        statsDirectory = appSupport.appendingPathComponent("ScreenBlocker/Stats", isDirectory: true)

        // Create directory if needed
        try? FileManager.default.createDirectory(at: statsDirectory, withIntermediateDirectories: true)

        setupSleepWakeObservers()
    }

    // MARK: - Sleep/Wake Detection

    private func setupSleepWakeObservers() {
        let workspace = NSWorkspace.shared.notificationCenter

        workspace.addObserver(
            self,
            selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )

        workspace.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc private func systemWillSleep(_ notification: Notification) {
        if currentRecord != nil {
            sleepOccurredDuringBlock = true
        }
    }

    @objc private func systemDidWake(_ notification: Notification) {
        // If a block was active when we went to sleep, drop that record
        // ScheduleManager will call startBlock on next cycle if block is still active
        if sleepOccurredDuringBlock {
            currentRecord = nil
            sleepOccurredDuringBlock = false
        }
    }

    // MARK: - Recording

    func startBlock(scheduleName: String) {
        // Only start a new record if we don't have one active
        guard currentRecord == nil else { return }

        sleepOccurredDuringBlock = false
        currentRecord = BlockRecord(
            id: UUID(),
            scheduleName: scheduleName,
            start: Date(),
            end: Date(), // Will be updated when block ends
            reason: .completed // Default, will be updated
        )
    }

    func endBlock(reason: BlockEndReason) {
        guard var record = currentRecord else { return }

        // Don't record if sleep occurred during the block
        if sleepOccurredDuringBlock {
            currentRecord = nil
            sleepOccurredDuringBlock = false
            return
        }

        record.end = Date()
        record.reason = reason

        saveRecord(record)
        currentRecord = nil
    }

    /// Called when user snoozes - records the postponement and starts a new tracking period
    func recordPostponement() {
        guard var record = currentRecord else { return }

        // Don't record if sleep occurred
        if sleepOccurredDuringBlock {
            // Reset for the new snooze period
            sleepOccurredDuringBlock = false
            currentRecord?.start = Date()
            return
        }

        record.end = Date()
        record.reason = .postponed
        saveRecord(record)

        // Start a new record for the snooze period
        currentRecord = BlockRecord(
            id: UUID(),
            scheduleName: record.scheduleName,
            start: Date(),
            end: Date(),
            reason: .completed
        )
    }

    // MARK: - Persistence

    private func fileURL(for date: Date) -> URL {
        let filename = Self.monthFormatter.string(from: date) + ".json"
        return statsDirectory.appendingPathComponent(filename)
    }

    private func saveRecord(_ record: BlockRecord) {
        let url = fileURL(for: record.start)
        var records = loadRecords(from: url)
        records.append(record)

        do {
            let data = try JSONEncoder().encode(records)
            try data.write(to: url, options: .atomic)
        } catch {
            print("Failed to save stats record: \(error)")
        }
    }

    private func loadRecords(from url: URL) -> [BlockRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([BlockRecord].self, from: data)
        } catch {
            print("Failed to load stats from \(url.lastPathComponent): \(error)")
            // Return empty rather than crashing - data may be corrupted
            return []
        }
    }

    // MARK: - Querying

    func records(for period: StatsPeriod, offset: Int = 0) -> [BlockRecord] {
        let calendar = Calendar.current
        let now = Date()

        let (startDate, endDate) = period.dateRange(from: now, offset: offset)

        // Determine which month files to load
        var allRecords: [BlockRecord] = []

        // Load records from relevant months
        var checkDate = startDate
        while checkDate <= endDate {
            let url = fileURL(for: checkDate)
            allRecords.append(contentsOf: loadRecords(from: url))

            // Move to next month
            guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: checkDate) else { break }
            checkDate = calendar.date(from: calendar.dateComponents([.year, .month], from: nextMonth)) ?? nextMonth
        }

        // Filter to records that overlap with the date range
        return allRecords.filter { record in
            record.end > startDate && record.start < endDate
        }
    }

    func totalDuration(for period: StatsPeriod, offset: Int = 0) -> TimeInterval {
        let (startDate, endDate) = period.dateRange(from: Date(), offset: offset)

        // Sum durations, clamping to the period boundaries
        return records(for: period, offset: offset).reduce(0) { total, record in
            let clampedStart = max(record.start, startDate)
            let clampedEnd = min(record.end, endDate)
            return total + clampedEnd.timeIntervalSince(clampedStart)
        }
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
