import Foundation
import UserNotifications
import AppKit

class ScheduleManager: ObservableObject {
    static let shared: ScheduleManager = {
        let manager = ScheduleManager(
            defaults: .standard,
            stats: .shared,
            overlay: OverlayWindowController.shared,
            notificationCenter: SystemNotificationCenter()
        )
        manager.startMonitoring()
        return manager
    }()

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
    private var snoozedScheduleID: UUID?  // Track which schedule was snoozed for reliable resume

    private let schedulesKey = "ScreenBlocker.schedules"
    private let unreadableSchedulesBackupKey = "ScreenBlocker.schedules.unreadableBackup"
    private let notificationLeadTimeKey = "ScreenBlocker.notificationLeadTime"

    private let defaults: UserDefaults
    private let stats: StatsManager
    private let overlay: OverlayPresenting
    private let notificationCenter: NotificationScheduling

    /// Creates a manager without starting the monitoring timer (tests drive `checkSchedules` directly).
    init(
        defaults: UserDefaults,
        stats: StatsManager,
        overlay: OverlayPresenting,
        notificationCenter: NotificationScheduling
    ) {
        self.defaults = defaults
        self.stats = stats
        self.overlay = overlay
        self.notificationCenter = notificationCenter
        loadSchedules()
        loadSettings()
    }

    // MARK: - Persistence

    private func loadSchedules() {
        guard let data = defaults.data(forKey: schedulesKey) else {
            // First run - start with empty schedules, user will create their own
            schedules = []
            return
        }

        do {
            schedules = try JSONDecoder().decode([Schedule].self, from: data)
        } catch {
            print("Failed to decode schedules (data may be corrupted): \(error)")
            // Keep the unreadable data under a separate key, since the next save overwrites the original
            defaults.set(data, forKey: unreadableSchedulesBackupKey)
            schedules = []
        }
    }

    func saveSchedules() {
        if let data = try? JSONEncoder().encode(schedules) {
            defaults.set(data, forKey: schedulesKey)
        }
        updateNextBlockTime()
        scheduleUpcomingNotifications()
    }

    private func loadSettings() {
        if defaults.object(forKey: notificationLeadTimeKey) != nil {
            notificationLeadTime = defaults.integer(forKey: notificationLeadTimeKey)
        }
    }

    func saveSettings() {
        defaults.set(notificationLeadTime, forKey: notificationLeadTimeKey)
        scheduleUpcomingNotifications()
    }

    // MARK: - Monitoring

    func startMonitoring() {
        // Check every second for accuracy. Common modes keep it firing while a menu is open.
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkSchedules()
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        checkTimer = timer

        let workspace = NSWorkspace.shared.notificationCenter

        // Observe system sleep to pause stats tracking
        workspace.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSystemSleep()
        }

        // Observe system wake to immediately reconcile schedule state
        // (timers don't fire during sleep, so state may be stale after wake)
        workspace.addObserver(
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

    /// Handle system sleep - pause stats if blocking
    func handleSystemSleep() {
        if isBlocking || snoozeEndTime != nil {
            stats.pauseForSleep()
        }
    }

    /// Handle system wake - immediately reconcile schedule state
    func handleSystemWake() {
        // Timers don't fire during sleep, so schedule state may be stale.
        // Force an immediate check to show/hide overlay as appropriate.
        // Note: checkSchedules() handles resuming stats from sleep based on actual state
        checkSchedules(isWakingFromSleep: true)

        // If blocking but overlay windows may have been torn down during sleep,
        // ensure they exist by refreshing the overlay
        if isBlocking {
            overlay.ensureOverlayVisible()
        }

        // Re-schedule notifications (some may have been missed during sleep)
        scheduleUpcomingNotifications()

        // Clean up any stale delivered notifications
        pruneStaleDeliveredNotifications()
    }

    func checkSchedules(isWakingFromSleep: Bool = false) {
        let now = AppClock.now()

        // When a block's start passes, its next occurrence needs a fresh notification
        let previousNextBlockStartTime = nextBlockStartTime
        defer {
            if nextBlockStartTime != previousNextBlockStartTime {
                scheduleUpcomingNotifications()
            }
        }

        // Track if we're resuming from snooze this tick
        var resumingFromSnooze = false

        // Check if we're in snooze mode
        if let snoozeEnd = snoozeEndTime, now < snoozeEnd {
            // Still in snooze, don't block
            if isBlocking {
                isBlocking = false
                overlay.hideOverlay()
            }
            // If waking from sleep while snoozed, resume to snoozed state
            if isWakingFromSleep {
                stats.resumeFromSleep(to: .snoozed)
            }
            updateNextBlockTime()
            return
        } else if snoozeEndTime != nil {
            // Snooze expired - clear snooze state
            snoozeEndTime = nil
            resumingFromSnooze = true
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
                    if resumingFromSnooze {
                        stats.resumeFromSnooze()
                    }
                    overlay.showOverlay()
                }
                if isWakingFromSleep {
                    stats.resumeFromSleep(to: .active)
                }
                updateNextBlockTime()
                return
            } else {
                // Manual block ended naturally (timed out)
                stats.endSession(reason: .completed)
                manualBlockSchedule = nil
                isManualBlock = false
                isBlocking = false
                currentBlockStartTime = nil
                currentBlockEndTime = nil
                activeSchedule = nil
                snoozedScheduleID = nil
                overlay.hideOverlay()
            }
        }

        // Clean up expired exited schedules
        exitedSchedules = exitedSchedules.filter { $0.value > now }

        // Check if any schedule is currently active
        var shouldBlock = false
        var blockEnd: Date?
        var currentActiveSchedule: Schedule?

        // Check for resumed postponed block (snooze expired but extended end time not yet reached)
        if let scheduleID = snoozedScheduleID {
            if let endTime = currentBlockEndTime,
               now < endTime,
               let schedule = schedules.first(where: { $0.id == scheduleID && $0.isEnabled }),
               exitedSchedules[scheduleID] == nil || exitedSchedules[scheduleID]! <= now {
                // Resume the postponed block
                shouldBlock = true
                blockEnd = endTime
                currentActiveSchedule = schedule
            } else {
                // Extended end has passed, or the schedule was deleted/disabled while snoozed
                if resumingFromSnooze {
                    stats.endSession(reason: .cancelled)
                }
                snoozedScheduleID = nil
                currentBlockEndTime = nil
            }
        }

        for schedule in schedules where schedule.isActive(at: now) {
            // Skip schedules that were manually exited (until their natural end time)
            if let exitedUntil = exitedSchedules[schedule.id], now < exitedUntil {
                continue
            }
            shouldBlock = true

            // Overlapping schedules form one block, named after the schedule that ends last
            let endTime = computeScheduleEndTime(for: schedule, at: now)
            if blockEnd == nil || endTime > blockEnd! {
                blockEnd = endTime
                currentActiveSchedule = schedule
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
                // Each call only applies in its matching state, so at most one takes effect
                if isWakingFromSleep {
                    stats.resumeFromSleep(to: .active)
                }
                if resumingFromSnooze {
                    stats.resumeFromSnooze()
                }
                if !stats.hasActiveSession {
                    stats.startSession(scheduleName: currentActiveSchedule?.displayName ?? "Unknown", scheduleID: currentActiveSchedule?.id)
                }
                overlay.showOverlay()
            } else {
                stats.endSession(reason: .completed)
                overlay.hideOverlay()
                currentBlockStartTime = nil
                currentBlockEndTime = nil
                activeSchedule = nil
                snoozedScheduleID = nil
                isManualBlock = false
            }
        } else if shouldBlock {
            currentBlockEndTime = blockEnd
            activeSchedule = currentActiveSchedule
            // Waking mid-block: the session is still marked as sleeping
            if isWakingFromSleep {
                stats.resumeFromSleep(to: .active)
            }
        }

        // If waking from sleep with an open session but nothing is blocking, end the session
        if isWakingFromSleep && !shouldBlock && stats.hasActiveSession {
            stats.endSession(reason: .completed)
        }

        updateNextBlockTime()
    }

    private func updateNextBlockTime() {
        let now = AppClock.now()
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
        let now = AppClock.now()
        snoozeEndTime = now.addingTimeInterval(TimeInterval(minutes * 60))
        snoozedScheduleID = activeSchedule?.id  // Track for reliable resume after snooze

        // Pause stats tracking during snooze
        stats.pauseForSnooze()

        // Extend the block end time
        if let currentEnd = currentBlockEndTime {
            currentBlockEndTime = currentEnd.addingTimeInterval(TimeInterval(minutes * 60))
        }

        isBlocking = false
        overlay.hideOverlay()
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
        let center = notificationCenter
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])

        schedules.removeAll { $0.id == schedule.id }
        saveSchedules()
    }

    /// Whether a schedule can be resumed: it's within its scheduled time (e.g. after exiting early),
    /// or it's the block that's currently snoozed
    func canResume(_ schedule: Schedule) -> Bool {
        schedule.isActive(at: AppClock.now()) || (isSnoozed && activeSchedule?.id == schedule.id)
    }

    /// Resume an interrupted schedule now, running until the end of its current occurrence
    func startManualBlock(from schedule: Schedule) {
        let now = AppClock.now()
        guard canResume(schedule) else { return }

        // Check if we're resuming from snooze (preserve extended end time)
        let isResumingFromSnooze = snoozeEndTime != nil && activeSchedule?.id == schedule.id

        manualBlockSchedule = schedule
        currentBlockStartTime = now

        // Preserve extended end time if resuming from snooze, otherwise use this occurrence's end
        if !isResumingFromSnooze || currentBlockEndTime == nil {
            currentBlockEndTime = computeScheduleEndTime(for: schedule, at: now)
        }

        activeSchedule = schedule
        isBlocking = true
        isManualBlock = true
        snoozeEndTime = nil

        // Resume from snooze or start new session
        if isResumingFromSnooze {
            stats.resumeFromSnooze()
        } else {
            // Replacing a different (snoozed) block: close its session rather than reusing it
            stats.endSession(reason: .cancelled)
            snoozedScheduleID = nil
            stats.startSession(scheduleName: schedule.displayName, scheduleID: schedule.id)
        }
        overlay.showOverlay()
    }

    /// Exit the current block early, scheduled or manual (user chose to exit)
    func exitBlockEarly() {
        stats.endSession(reason: .exited)

        // Mark every schedule in the block as exited until its natural end time (not extended by snooze),
        // so an overlapping schedule doesn't immediately re-block
        let now = AppClock.now()
        var exiting = schedules.filter { $0.isActive(at: now) }
        if let schedule = activeSchedule, !exiting.contains(where: { $0.id == schedule.id }) {
            exiting.append(schedule)
        }
        for schedule in exiting {
            exitedSchedules[schedule.id] = computeScheduleEndTime(for: schedule, at: now)
        }

        manualBlockSchedule = nil
        currentBlockStartTime = nil
        currentBlockEndTime = nil
        activeSchedule = nil
        snoozedScheduleID = nil
        isBlocking = false
        isManualBlock = false

        overlay.hideOverlay()
    }

    /// Close any open stats session when the app quits (including logout/shutdown)
    func handleAppTermination() {
        stats.endSession(reason: .cancelled)
    }

    // MARK: - Notifications

    private func pruneStaleDeliveredNotifications() {
        let center = notificationCenter
        let validScheduleIDs = Set(schedules.map { $0.id.uuidString })

        center.getDeliveredNotificationIdentifiers { identifiers in
            let staleIdentifiers = identifiers.compactMap { identifier -> String? in
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

    func scheduleUpcomingNotifications() {
        let center = notificationCenter

        // Remove existing notifications
        center.removeAllPendingNotificationRequests()

        guard notificationLeadTime > 0 else { return }

        let now = AppClock.now()
        let calendar = Calendar.current

        // Queue each schedule's next occurrence (re-run whenever the next block moves on)
        for schedule in schedules where schedule.isEnabled {
            guard let nextStart = schedule.nextStart(after: now) else { continue }

            let notifyTime = nextStart.addingTimeInterval(TimeInterval(-notificationLeadTime * 60))
            guard notifyTime > now else { continue }

            let content = UNMutableNotificationContent()
            content.title = "Screen Block Starting Soon"
            let minutes = notificationLeadTime == 1 ? "1 minute" : "\(notificationLeadTime) minutes"
            content.body = "\(schedule.displayName) begins in \(minutes)"
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
        return AppClock.now() < snoozeEnd
    }

    var timeUntilNextBlock: String? {
        let now = AppClock.now()

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
