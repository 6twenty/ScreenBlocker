import Foundation
import UserNotifications

class ScheduleManager: ObservableObject {
    static let shared = ScheduleManager()

    @Published var schedules: [Schedule] = []
    @Published var isBlocking: Bool = false
    @Published var currentBlockEndTime: Date?
    @Published var nextBlockStartTime: Date?
    @Published var notificationLeadTime: Int = 5 // minutes before block

    private var checkTimer: Timer?
    private var snoozeEndTime: Date?

    private let schedulesKey = "ScreenBlocker.schedules"
    private let notificationLeadTimeKey = "ScreenBlocker.notificationLeadTime"

    private init() {
        loadSchedules()
        loadSettings()
        startMonitoring()
    }

    // MARK: - Persistence

    private func loadSchedules() {
        if let data = UserDefaults.standard.data(forKey: schedulesKey),
           let decoded = try? JSONDecoder().decode([Schedule].self, from: data) {
            schedules = decoded
        } else {
            // Default schedules for demo
            schedules = [
                Schedule(
                    name: "Morning Break",
                    startHour: 10,
                    startMinute: 30,
                    endHour: 10,
                    endMinute: 45,
                    enabledDays: Set([.monday, .tuesday, .wednesday, .thursday, .friday])
                ),
                Schedule(
                    name: "Lunch",
                    startHour: 13,
                    startMinute: 0,
                    endHour: 14,
                    endMinute: 0,
                    enabledDays: Set([.monday, .tuesday, .wednesday, .thursday, .friday])
                )
            ]
        }
    }

    func saveSchedules() {
        if let data = try? JSONEncoder().encode(schedules) {
            UserDefaults.standard.set(data, forKey: schedulesKey)
        }
        updateNextBlockTime()
        scheduleUpcomingNotifications()
    }

    private func loadSettings() {
        if UserDefaults.standard.object(forKey: notificationLeadTimeKey) != nil {
            notificationLeadTime = UserDefaults.standard.integer(forKey: notificationLeadTimeKey)
        }
    }

    func saveSettings() {
        UserDefaults.standard.set(notificationLeadTime, forKey: notificationLeadTimeKey)
        scheduleUpcomingNotifications()
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        // Check every second for accuracy
        checkTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkSchedules()
        }
        checkTimer?.tolerance = 0.1

        // Initial check
        checkSchedules()
        scheduleUpcomingNotifications()
    }

    private func checkSchedules() {
        let now = Date()

        // Check if we're in snooze mode
        if let snoozeEnd = snoozeEndTime, now < snoozeEnd {
            // Still in snooze, don't block
            if isBlocking {
                isBlocking = false
                OverlayWindowController.shared.hideOverlay()
            }
            updateNextBlockTime()
            return
        } else if snoozeEndTime != nil {
            // Snooze expired
            snoozeEndTime = nil
        }

        // Check if any schedule is currently active
        var shouldBlock = false
        var blockEnd: Date?

        for schedule in schedules where schedule.isActive(at: now) {
            shouldBlock = true

            // Calculate end time for today
            let calendar = Calendar.current
            var components = calendar.dateComponents([.year, .month, .day], from: now)
            components.hour = schedule.endHour
            components.minute = schedule.endMinute
            components.second = 0

            if let endTime = calendar.date(from: components) {
                if blockEnd == nil || endTime > blockEnd! {
                    blockEnd = endTime
                }
            }
        }

        // Apply any snooze extension to end time
        if let currentEnd = currentBlockEndTime, shouldBlock {
            // Keep the extended end time if it's later
            if currentEnd > (blockEnd ?? Date.distantPast) {
                blockEnd = currentEnd
            }
        }

        // Check if we've passed the (possibly extended) end time
        if shouldBlock, let end = blockEnd, now >= end {
            shouldBlock = false
        }

        if shouldBlock != isBlocking {
            isBlocking = shouldBlock
            currentBlockEndTime = blockEnd

            if shouldBlock {
                OverlayWindowController.shared.showOverlay()
            } else {
                OverlayWindowController.shared.hideOverlay()
                currentBlockEndTime = nil
            }
        } else if shouldBlock {
            currentBlockEndTime = blockEnd
        }

        updateNextBlockTime()
    }

    private func updateNextBlockTime() {
        let now = Date()
        var earliest: Date?

        for schedule in schedules {
            if let next = schedule.nextStart(after: now) {
                if earliest == nil || next < earliest! {
                    earliest = next
                }
            }
        }

        nextBlockStartTime = earliest
    }

    // MARK: - Snooze

    func snooze(minutes: Int = 5) {
        let now = Date()
        snoozeEndTime = now.addingTimeInterval(TimeInterval(minutes * 60))

        // Extend the block end time
        if let currentEnd = currentBlockEndTime {
            currentBlockEndTime = currentEnd.addingTimeInterval(TimeInterval(minutes * 60))
        }

        isBlocking = false
        OverlayWindowController.shared.hideOverlay()
    }

    // MARK: - Schedule Management

    func addSchedule(_ schedule: Schedule) {
        schedules.append(schedule)
        saveSchedules()
    }

    func updateSchedule(_ schedule: Schedule) {
        if let index = schedules.firstIndex(where: { $0.id == schedule.id }) {
            schedules[index] = schedule
            saveSchedules()
        }
    }

    func deleteSchedule(_ schedule: Schedule) {
        schedules.removeAll { $0.id == schedule.id }
        saveSchedules()
    }

    // MARK: - Notifications

    private func scheduleUpcomingNotifications() {
        let center = UNUserNotificationCenter.current()

        // Remove existing notifications
        center.removeAllPendingNotificationRequests()

        guard notificationLeadTime > 0 else { return }

        let now = Date()
        let calendar = Calendar.current

        // Schedule notifications for the next 24 hours
        for schedule in schedules where schedule.isEnabled {
            guard let nextStart = schedule.nextStart(after: now) else { continue }

            // Only schedule if within next 24 hours
            let notifyTime = nextStart.addingTimeInterval(TimeInterval(-notificationLeadTime * 60))
            guard notifyTime > now,
                  nextStart.timeIntervalSince(now) < 86400 else { continue }

            let content = UNMutableNotificationContent()
            content.title = "Screen Block Starting Soon"
            content.body = "\(schedule.name) begins in \(notificationLeadTime) minutes"
            content.sound = .default

            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: notifyTime)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)

            let request = UNNotificationRequest(
                identifier: "block-\(schedule.id.uuidString)",
                content: content,
                trigger: trigger
            )

            center.add(request)
        }
    }

    // MARK: - Helpers

    var timeUntilNextBlock: String? {
        guard let next = nextBlockStartTime else { return nil }

        let now = Date()
        let interval = next.timeIntervalSince(now)

        guard interval > 0 else { return nil }

        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
}
