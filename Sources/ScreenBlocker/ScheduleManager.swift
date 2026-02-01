import Foundation
import UserNotifications
import AppKit

class ScheduleManager: ObservableObject {
    static let shared = ScheduleManager()

    @Published var schedules: [Schedule] = []
    @Published var isBlocking: Bool = false
    @Published var isManualBlock: Bool = false
    @Published var currentBlockStartTime: Date?
    @Published var currentBlockEndTime: Date?
    @Published var nextBlockStartTime: Date?
    @Published var nextSchedule: Schedule?
    @Published var activeSchedule: Schedule?
    @Published var notificationLeadTime: Int = 5 // minutes before block
    @Published var snoozeEndTime: Date?

    private var checkTimer: Timer?
    private var manualBlockSchedule: Schedule?
    private var exitedSchedules: [UUID: Date] = [:]  // Schedule ID -> suppressed until time

    private let schedulesKey = "ScreenBlocker.schedules"
    private let notificationLeadTimeKey = "ScreenBlocker.notificationLeadTime"

    private init() {
        loadSchedules()
        loadSettings()
        startMonitoring()
    }

    // MARK: - Persistence

    private func loadSchedules() {
        guard let data = UserDefaults.standard.data(forKey: schedulesKey) else {
            // First run - start with empty schedules, user will create their own
            schedules = []
            return
        }

        do {
            schedules = try JSONDecoder().decode([Schedule].self, from: data)
        } catch {
            print("Failed to decode schedules (data may be corrupted): \(error)")
            // Keep schedules empty rather than silently replacing with defaults
            schedules = []
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

        // Observe system wake to immediately reconcile schedule state
        // (timers don't fire during sleep, so state may be stale after wake)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSystemWake()
        }

        // Defer initial check to avoid recursive lock during singleton initialization
        // (OverlayView accesses ScheduleManager.shared, which would deadlock if still initializing)
        DispatchQueue.main.async { [weak self] in
            self?.checkSchedules()
            self?.pruneStaleDeliveredNotifications()
            self?.scheduleUpcomingNotifications()
        }
    }

    /// Handle system wake - immediately reconcile schedule state
    private func handleSystemWake() {
        // Timers don't fire during sleep, so schedule state may be stale.
        // Force an immediate check to show/hide overlay as appropriate.
        checkSchedules()

        // If blocking but overlay windows may have been torn down during sleep,
        // ensure they exist by refreshing the overlay
        if isBlocking {
            OverlayWindowController.shared.ensureOverlayVisible()
        }

        // Re-schedule notifications (some may have been missed during sleep)
        scheduleUpcomingNotifications()

        // Clean up any stale delivered notifications
        pruneStaleDeliveredNotifications()
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
            // Snooze expired - clear snooze state
            snoozeEndTime = nil
            // Clear block start time so fresh blocks get a new start time
            // (if the block resumes, it will be set below; if not, we need it cleared)
            currentBlockStartTime = nil
        }

        // Check for manual block first
        if let manualSchedule = manualBlockSchedule, let endTime = currentBlockEndTime {
            if now < endTime {
                // Manual block still active
                if !isBlocking {
                    isBlocking = true
                    activeSchedule = manualSchedule
                    OverlayWindowController.shared.showOverlay()
                }
                updateNextBlockTime()
                return
            } else {
                // Manual block ended naturally (timed out)
                StatsManager.shared.endBlock(reason: .completed)
                manualBlockSchedule = nil
                isManualBlock = false
                isBlocking = false
                currentBlockStartTime = nil
                currentBlockEndTime = nil
                activeSchedule = nil
                OverlayWindowController.shared.hideOverlay()
            }
        }

        // Clean up expired exited schedules
        exitedSchedules = exitedSchedules.filter { $0.value > now }

        // Check if any schedule is currently active
        var shouldBlock = false
        var blockEnd: Date?
        var currentActiveSchedule: Schedule?

        for schedule in schedules where schedule.isActive(at: now) {
            // Skip schedules that were manually exited (until their natural end time)
            if let exitedUntil = exitedSchedules[schedule.id], now < exitedUntil {
                continue
            }
            shouldBlock = true
            currentActiveSchedule = schedule

            let endTime = computeScheduleEndTime(for: schedule, at: now)
            if blockEnd == nil || endTime > blockEnd! {
                blockEnd = endTime
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
            currentActiveSchedule = nil
        }

        if shouldBlock != isBlocking {
            isBlocking = shouldBlock
            currentBlockEndTime = blockEnd
            activeSchedule = currentActiveSchedule

            if shouldBlock {
                isManualBlock = false  // This is a scheduled block, not manual
                currentBlockStartTime = now
                StatsManager.shared.startBlock(scheduleName: currentActiveSchedule?.name ?? "Unknown")
                OverlayWindowController.shared.showOverlay()
            } else {
                StatsManager.shared.endBlock(reason: .completed)
                OverlayWindowController.shared.hideOverlay()
                currentBlockStartTime = nil
                currentBlockEndTime = nil
                activeSchedule = nil
                isManualBlock = false
            }
        } else if shouldBlock {
            currentBlockEndTime = blockEnd
            activeSchedule = currentActiveSchedule
            // Ensure stats are recording (e.g., after wake from sleep when record was dropped)
            StatsManager.shared.startBlock(scheduleName: currentActiveSchedule?.name ?? "Unknown")
        }

        updateNextBlockTime()
    }

    private func updateNextBlockTime() {
        let now = Date()
        var earliest: Date?
        var earliestSchedule: Schedule?

        for schedule in schedules {
            if let next = schedule.nextStart(after: now) {
                if earliest == nil || next < earliest! {
                    earliest = next
                    earliestSchedule = schedule
                }
            }
        }

        nextBlockStartTime = earliest
        nextSchedule = earliestSchedule
    }

    /// Compute a schedule's natural end time (without snooze extensions)
    private func computeScheduleEndTime(for schedule: Schedule, at now: Date) -> Date {
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = schedule.endHour
        components.minute = schedule.endMinute
        components.second = 0

        guard let endTime = calendar.date(from: components) else { return now }

        let isOvernight = schedule.endHour < schedule.startHour ||
            (schedule.endHour == schedule.startHour && schedule.endMinute <= schedule.startMinute)

        if isOvernight {
            let currentHour = calendar.component(.hour, from: now)
            let currentMinute = calendar.component(.minute, from: now)
            let currentMinutes = currentHour * 60 + currentMinute

            // Only add a day if we're before midnight (after start time)
            if currentMinutes >= schedule.startHour * 60 + schedule.startMinute {
                return calendar.date(byAdding: .day, value: 1, to: endTime) ?? endTime
            }
        }

        return endTime
    }

    // MARK: - Snooze

    func snooze(minutes: Int = 5) {
        let now = Date()
        snoozeEndTime = now.addingTimeInterval(TimeInterval(minutes * 60))

        // Record the postponement before hiding
        StatsManager.shared.recordPostponement()

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
        // Remove notifications for this specific schedule (both pending and delivered)
        let identifier = "block-\(schedule.id.uuidString)"
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])

        schedules.removeAll { $0.id == schedule.id }
        saveSchedules()
    }

    /// Manually start a block using the given schedule's end time
    func startManualBlock(from schedule: Schedule) {
        let now = Date()

        // Check if we're resuming from snooze (preserve extended end time)
        let isResumingFromSnooze = snoozeEndTime != nil && activeSchedule?.id == schedule.id

        manualBlockSchedule = schedule
        currentBlockStartTime = now

        // Preserve extended end time if resuming from snooze, otherwise compute fresh
        if !isResumingFromSnooze || currentBlockEndTime == nil {
            currentBlockEndTime = computeNextEndTime(for: schedule, at: now)
        }

        activeSchedule = schedule
        isBlocking = true
        isManualBlock = true
        snoozeEndTime = nil

        // Only start new stats record if not resuming from snooze
        if !isResumingFromSnooze {
            StatsManager.shared.startBlock(scheduleName: schedule.name)
        }
        OverlayWindowController.shared.showOverlay()
    }

    /// Compute the next valid end time for a schedule (today if not passed, otherwise tomorrow)
    private func computeNextEndTime(for schedule: Schedule, at now: Date) -> Date {
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = schedule.endHour
        components.minute = schedule.endMinute
        components.second = 0

        guard let endTime = calendar.date(from: components) else { return now }

        // If end time has already passed today (with 1 minute buffer), use tomorrow
        if endTime.timeIntervalSince(now) < 60 {
            return calendar.date(byAdding: .day, value: 1, to: endTime) ?? endTime
        }

        return endTime
    }

    /// Stop a manual block immediately
    func stopManualBlock() {
        StatsManager.shared.endBlock(reason: .exited)

        // Mark schedule as exited to prevent immediate re-trigger if within scheduled window
        if let schedule = activeSchedule {
            let scheduleEndTime = computeScheduleEndTime(for: schedule, at: Date())
            exitedSchedules[schedule.id] = scheduleEndTime
        }

        manualBlockSchedule = nil
        currentBlockStartTime = nil
        currentBlockEndTime = nil
        activeSchedule = nil
        isBlocking = false
        isManualBlock = false

        OverlayWindowController.shared.hideOverlay()
    }

    /// Exit a scheduled block early (user chose to exit)
    func exitBlockEarly() {
        StatsManager.shared.endBlock(reason: .exited)

        // Mark this specific schedule as exited until its natural end time (not extended by snooze)
        if let schedule = activeSchedule {
            let scheduleEndTime = computeScheduleEndTime(for: schedule, at: Date())
            exitedSchedules[schedule.id] = scheduleEndTime
        }

        manualBlockSchedule = nil
        currentBlockStartTime = nil
        currentBlockEndTime = nil
        activeSchedule = nil
        isBlocking = false
        isManualBlock = false

        OverlayWindowController.shared.hideOverlay()
    }

    // MARK: - Notifications

    private func pruneStaleDeliveredNotifications() {
        let center = UNUserNotificationCenter.current()
        let validScheduleIDs = Set(schedules.map { $0.id.uuidString })

        center.getDeliveredNotifications { notifications in
            let staleIdentifiers = notifications.compactMap { notification -> String? in
                let identifier = notification.request.identifier
                // Notification identifiers are "block-<uuid>"
                guard identifier.hasPrefix("block-") else { return nil }
                let uuidString = String(identifier.dropFirst("block-".count))
                // If this UUID doesn't match any current schedule, it's stale
                if !validScheduleIDs.contains(uuidString) {
                    return identifier
                }
                return nil
            }

            if !staleIdentifiers.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: staleIdentifiers)
            }
        }
    }

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

    /// Whether a block is currently snoozed (will resume when snoozeEndTime is reached)
    var isSnoozed: Bool {
        guard let snoozeEnd = snoozeEndTime else { return false }
        return Date() < snoozeEnd
    }

    var timeUntilNextBlock: String? {
        let now = Date()

        // If snoozed, show time until snooze ends (block resumes)
        if let snoozeEnd = snoozeEndTime, now < snoozeEnd {
            return formatInterval(snoozeEnd.timeIntervalSince(now))
        }

        // Otherwise show time until next scheduled block
        guard let next = nextBlockStartTime else { return nil }
        let interval = next.timeIntervalSince(now)
        guard interval > 0 else { return nil }

        return formatInterval(interval)
    }

    private func formatInterval(_ interval: TimeInterval) -> String {
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        let seconds = Int(interval) % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else if minutes > 0 {
            return "\(minutes)m"
        } else {
            return "\(seconds)s"
        }
    }
}
