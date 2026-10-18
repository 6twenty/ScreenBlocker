import Foundation
import UserNotifications
import AppKit

class ScheduleManager: ObservableObject {
    static let shared: ScheduleManager = {
        let manager = ScheduleManager(
            defaults: .standard,
            stats: .shared,
            overlay: OverlayWindowController.shared,
            notificationCenter: SystemNotificationCenter(),
            pinLock: .shared
        )
        manager.startMonitoring()
        return manager
    }()

    @Published var schedules: [Schedule] = []
    @Published var isBlocking: Bool = false
    @Published var currentBlockEndTime: Date?
    @Published var nextBlockStartTime: Date?
    @Published var nextSchedule: Schedule?
    @Published var activeSchedule: Schedule? {
        didSet {
            if activeSchedule == nil { activeScheduleNaturalEnd = nil }
        }
    }
    @Published private(set) var notificationLeadTime: Int = 5 // minutes before block
    @Published private(set) var snoozeDuration: Int = 5 // minutes; 0 turns snoozing off
    @Published var snoozeEndTime: Date?
    /// Identifies the current block. Stays the same across overlaps, snoozes and handovers to an
    /// overlapping schedule; changes when a separate block starts.
    @Published private(set) var currentBlockID: UUID?

    private var checkTimer: Timer?
    private var manualBlockSchedule: Schedule?
    private var exitedSchedules: [UUID: Date] = [:]  // Schedule ID -> suppressed until time
    private var snoozedScheduleID: UUID? {  // Track which schedule was snoozed for reliable resume
        didSet {
            if snoozedScheduleID == nil { snoozedScheduleNaturalEnd = nil }
        }
    }
    // The snoozed schedule's own end, kept because recomputing it after midnight gives the wrong day
    private var snoozedScheduleNaturalEnd: Date?
    // Own (unsnoozed) end of the schedule currently naming the block
    private var activeScheduleNaturalEnd: Date?
    // Every schedule making up the current block
    private var currentBlockScheduleIDs: Set<UUID> = []
    // Each block can be snoozed once
    private var hasSnoozedThisBlock = false

    private let schedulesKey = "ScreenBlocker.schedules"
    private let unreadableSchedulesBackupKey = "ScreenBlocker.schedules.unreadableBackup"
    private let notificationLeadTimeKey = "ScreenBlocker.notificationLeadTime"
    private let snoozeDurationKey = "ScreenBlocker.snoozeDuration"

    private let defaults: UserDefaults
    private let stats: StatsManager
    private let overlay: OverlayPresenting
    private let notificationCenter: NotificationScheduling
    private let pinLock: PinLock

    /// Creates a manager without starting the monitoring timer (tests drive `checkSchedules` directly).
    init(
        defaults: UserDefaults,
        stats: StatsManager,
        overlay: OverlayPresenting,
        notificationCenter: NotificationScheduling,
        pinLock: PinLock
    ) {
        self.defaults = defaults
        self.stats = stats
        self.overlay = overlay
        self.notificationCenter = notificationCenter
        self.pinLock = pinLock
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
        if defaults.object(forKey: snoozeDurationKey) != nil {
            snoozeDuration = defaults.integer(forKey: snoozeDurationKey)
        }
    }

    // Settings changes are refused while the PIN is on and Settings are locked

    @discardableResult
    func setNotificationLeadTime(_ minutes: Int) -> Bool {
        guard pinLock.canEditSettings else { return false }
        notificationLeadTime = minutes
        saveSettings()
        return true
    }

    @discardableResult
    func setSnoozeDuration(_ minutes: Int) -> Bool {
        guard pinLock.canEditSettings else { return false }
        snoozeDuration = minutes
        saveSettings()
        return true
    }

    private func saveSettings() {
        defaults.set(notificationLeadTime, forKey: notificationLeadTimeKey)
        defaults.set(snoozeDuration, forKey: snoozeDurationKey)
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
            updateNextBlockTime()
            if nextBlockStartTime != previousNextBlockStartTime {
                scheduleUpcomingNotifications()
            }
        }

        // A session that's over is closed at its block's end, even if that passed while asleep
        let sessionEnd = min(now, currentBlockEndTime ?? now)

        let snoozeExpired = snoozeEndTime.map { now >= $0 } ?? false
        if snoozeExpired {
            snoozeEndTime = nil
        }
        // Schedules exited early stay suppressed until their natural end
        exitedSchedules = exitedSchedules.filter { $0.value > now }

        switch decideBlock(at: now, snoozeExpired: snoozeExpired) {
        case .snoozed:
            if isWakingFromSleep {
                stats.resumeFromSleep(to: .snoozed)
            }
            if isBlocking {
                isBlocking = false
                overlay.hideOverlay()
            }

        case .idle(let reason):
            // Whatever session is still open is over
            stats.endSession(reason: reason, at: sessionEnd)
            if isBlocking {
                overlay.hideOverlay()
            }
            clearBlock()

        case .blocking(let block, let closingPrevious):
            if let reason = closingPrevious {
                stats.endSession(reason: reason, at: sessionEnd)
            }
            // Only a wake leaves the sleeping state, since a tick can still run after the sleep notice
            if isWakingFromSleep {
                stats.resumeFromSleep(to: .active)
            }
            stats.resumeFromSnooze()  // No-op unless the session is snoozed
            if stats.hasActiveSession {
                // A later-ending overlap may have taken over the block, and now names it
                stats.updateCurrentSession(scheduleName: block.owner.displayName, scheduleID: block.owner.id)
            } else {
                stats.startSession(scheduleName: block.owner.displayName, scheduleID: block.owner.id)
            }

            if closingPrevious != nil || currentBlockID == nil {
                beginBlock()
            }
            manualBlockSchedule = block.isManual ? block.owner : nil
            currentBlockScheduleIDs = block.scheduleIDs
            snoozedScheduleID = block.snoozedScheduleID
            currentBlockEndTime = block.end
            activeSchedule = block.owner
            activeScheduleNaturalEnd = block.ownerEnd
            if !isBlocking {
                isBlocking = true
                overlay.showOverlay()
            }
        }
    }

    /// What the block should be doing this tick
    private enum BlockDecision {
        /// Paused by a snooze that hasn't run out
        case snoozed
        /// Nothing to block. Any open session is over, for this reason.
        case idle(EndReason)
        /// Block, or keep blocking. `closingPrevious` is set when the open session is over
        /// rather than continuing into this block.
        case blocking(Block, closingPrevious: EndReason?)
    }

    private struct Block {
        let owner: Schedule           // Names the block
        let scheduleIDs: Set<UUID>    // Every schedule making up the block
        let end: Date                 // Combined end, including any snooze extension
        let ownerEnd: Date?           // The owner's own (unsnoozed) end
        let isManual: Bool
        let snoozedScheduleID: UUID?  // The resumed snoozed schedule, while the block still runs on its extension
    }

    /// Works out what the block should be doing now from the schedules and the previous tick's state,
    /// without changing anything
    private func decideBlock(at now: Date, snoozeExpired: Bool) -> BlockDecision {
        if snoozeEndTime != nil {
            return .snoozed
        }

        // The previous block's (possibly snooze-extended) end decides whether an active schedule continues it
        let previousBlockEnd = currentBlockEndTime
        // That end, and the snoozed schedule, carry over until the block they belong to is over
        var carriedEnd = currentBlockEndTime
        var snoozedID = snoozedScheduleID
        // The open session is over for this reason, even if something else is blocking now
        var forcedEnd: EndReason?
        // The reason to close the open session with, if nothing continues it
        var endReason = EndReason.completed

        if let manual = manualBlockSchedule {
            if !isScheduleAvailable(manual.id) {
                // A resumed block whose schedule was deleted or disabled (only possible while snoozed)
                forcedEnd = .cancelled
            } else if let end = currentBlockEndTime, now < end {
                let block = Block(owner: manual, scheduleIDs: [manual.id], end: end, ownerEnd: activeScheduleNaturalEnd,
                                  isManual: true, snoozedScheduleID: nil)
                return .blocking(block, closingPrevious: nil)
            }
            // Otherwise it ran to its end. An overlapping schedule that's already running carries the block on.
            carriedEnd = nil
            snoozedID = nil
        }

        var owner: Schedule?
        var scheduleIDs: Set<UUID> = []
        var ownerEnd: Date?     // Natural end of the schedule that names the block
        var blockEnd: Date?     // Combined end, including any snooze extension
        // Whether this continues the previous block, rather than being a separate one that took over
        var continuesPreviousBlock = previousBlockEnd == nil

        // A resumed snooze runs on until its extended end, even past its schedule's own end
        if let id = snoozedID {
            if let end = carriedEnd, now < end,
               let schedule = schedules.first(where: { $0.id == id && $0.isEnabled }),
               exitedSchedules[id] == nil {
                owner = schedule
                scheduleIDs.insert(id)
                ownerEnd = snoozedScheduleNaturalEnd ?? computeScheduleEndTime(for: schedule, at: now)
                blockEnd = end
                continuesPreviousBlock = true
            } else {
                if snoozeExpired {
                    if isScheduleAvailable(id) {
                        // Ran past its extended end while snoozed: cancelled, unless an overlap continues it
                        endReason = .cancelled
                    } else {
                        // Deleted or disabled while snoozed
                        forcedEnd = .cancelled
                    }
                }
                carriedEnd = nil
                snoozedID = nil
            }
        }

        for schedule in schedules where schedule.isActive(at: now) && exitedSchedules[schedule.id] == nil {
            // Started before the previous block ended, so it overlaps and continues that block
            if let previousBlockEnd, computeScheduleStartTime(for: schedule, at: now) < previousBlockEnd {
                continuesPreviousBlock = true
            }
            scheduleIDs.insert(schedule.id)

            // Overlapping schedules form one block, named after the schedule whose own (unsnoozed)
            // end is latest, so a snooze extension can't flip the name back and forth
            let endTime = computeScheduleEndTime(for: schedule, at: now)
            if blockEnd == nil || endTime > blockEnd! {
                blockEnd = endTime
            }
            if ownerEnd == nil || endTime > ownerEnd! {
                ownerEnd = endTime
                owner = schedule
            }
        }

        // Keep any snooze extension
        if let carriedEnd, let end = blockEnd, carriedEnd > end {
            blockEnd = carriedEnd
        }

        guard let owner, let blockEnd, now < blockEnd else {
            return .idle(forcedEnd ?? endReason)
        }

        // When the previous block is over and a separate one has taken over (back-to-back blocks,
        // or one that started while asleep), the old session closes and a new one starts
        let closingPrevious = forcedEnd ?? (continuesPreviousBlock ? nil : endReason)
        let block = Block(owner: owner, scheduleIDs: scheduleIDs, end: blockEnd, ownerEnd: ownerEnd,
                          isManual: false, snoozedScheduleID: snoozedID)
        return .blocking(block, closingPrevious: closingPrevious)
    }

    /// A separate block is starting
    private func beginBlock() {
        currentBlockID = UUID()
        hasSnoozedThisBlock = false
        pinLock.lockSettings()
    }

    /// Forget the current block once it's over (ended, exited or cancelled)
    private func clearBlock() {
        isBlocking = false
        manualBlockSchedule = nil
        currentBlockEndTime = nil
        activeSchedule = nil
        snoozedScheduleID = nil
        if currentBlockID != nil {
            currentBlockID = nil
        }
        currentBlockScheduleIDs = []
        hasSnoozedThisBlock = false
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

    /// Start of a schedule's current occurrence (yesterday's start for an overnight block after midnight)
    private func computeScheduleStartTime(for schedule: Schedule, at now: Date) -> Date {
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = schedule.startHour
        components.minute = schedule.startMinute
        components.second = 0

        guard let startTime = calendar.date(from: components) else { return now }
        if startTime > now {
            return calendar.date(byAdding: .day, value: -1, to: startTime) ?? startTime
        }
        return startTime
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

    /// Whether the block can be snoozed now: snoozing is on, once per block, and only if every schedule in it allows it
    var canSnooze: Bool {
        guard snoozeDuration > 0, isBlocking, !hasSnoozedThisBlock, !currentBlockScheduleIDs.isEmpty else { return false }
        return currentBlockScheduleIDs.allSatisfy { id in
            schedules.first { $0.id == id }?.allowsSnooze ?? false
        }
    }

    /// Snooze the block for `minutes` (the snooze length setting by default), if allowed. `blockID` is the block
    /// the request was made for (e.g. when a dialog opened); it's refused if a different block is running by now.
    @discardableResult
    func snooze(minutes: Int? = nil, blockID: UUID? = nil) -> Bool {
        // Decide against the block as it is now, not as of the last tick
        checkSchedules()
        guard canSnooze, blockID == nil || blockID == currentBlockID else { return false }
        hasSnoozedThisBlock = true

        let minutes = minutes ?? snoozeDuration
        let now = AppClock.now()
        snoozeEndTime = now.addingTimeInterval(TimeInterval(minutes * 60))
        snoozedScheduleID = activeSchedule?.id  // Track for reliable resume after snooze
        snoozedScheduleNaturalEnd = activeScheduleNaturalEnd

        // Pause stats tracking during snooze
        stats.pauseForSnooze()

        // Extend the block end time
        if let currentEnd = currentBlockEndTime {
            currentBlockEndTime = currentEnd.addingTimeInterval(TimeInterval(minutes * 60))
        }

        isBlocking = false
        overlay.hideOverlay()
        return true
    }

    // MARK: - Schedule Management

    // Changes are refused while the PIN is on and Settings are locked

    func addSchedule(_ schedule: Schedule) {
        guard pinLock.canEditSettings else { return }
        schedules.append(schedule)
        saveSchedules()
    }

    func updateSchedule(_ schedule: Schedule) {
        guard pinLock.canEditSettings else { return }
        if let index = schedules.firstIndex(where: { $0.id == schedule.id }) {
            schedules[index] = schedule
            saveSchedules()
        }
    }

    func deleteSchedule(_ schedule: Schedule) {
        guard pinLock.canEditSettings else { return }
        // Remove notifications for this specific schedule (both pending and delivered)
        let identifier = "block-\(schedule.id.uuidString)"
        let center = notificationCenter
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])

        schedules.removeAll { $0.id == schedule.id }
        saveSchedules()
    }

    /// Whether a schedule can be resumed: nothing is blocking, and it's within its scheduled time
    /// (e.g. after exiting early) or it's the block that's currently snoozed
    func canResume(_ schedule: Schedule) -> Bool {
        guard !isBlocking, isScheduleAvailable(schedule.id) else { return false }
        return schedule.isActive(at: AppClock.now()) || (isSnoozed && activeSchedule?.id == schedule.id)
    }

    /// Resuming this schedule would replace a different, snoozed block (and drop its extended time),
    /// so it needs the PIN when that's on. Call `checkSchedules()` first so this reflects the block as it is now.
    func resumeReplacesSnoozedBlock(_ schedule: Schedule) -> Bool {
        isSnoozed && activeSchedule?.id != schedule.id
    }

    /// The schedule still exists and is enabled
    private func isScheduleAvailable(_ scheduleID: UUID) -> Bool {
        schedules.contains { $0.id == scheduleID && $0.isEnabled }
    }

    /// Resume an interrupted schedule now, running until the end of its current occurrence. With the PIN on,
    /// replacing a different snoozed block needs `replacingSnoozedBlock` set to that block's ID, once the PIN is entered.
    func startManualBlock(from schedule: Schedule, replacingSnoozedBlock authorizedBlockID: UUID? = nil) {
        // Decide against the block as it is now: a snooze may have just run out
        checkSchedules()
        let now = AppClock.now()
        guard canResume(schedule) else { return }
        if pinLock.isEnabled && resumeReplacesSnoozedBlock(schedule) {
            guard let authorizedBlockID, authorizedBlockID == currentBlockID else { return }
        }

        // Check if we're resuming from snooze (preserve extended end time)
        let isResumingFromSnooze = snoozeEndTime != nil && activeSchedule?.id == schedule.id

        manualBlockSchedule = schedule

        // Preserve extended end time if resuming from snooze, otherwise use this occurrence's end
        if !isResumingFromSnooze || currentBlockEndTime == nil {
            currentBlockEndTime = computeScheduleEndTime(for: schedule, at: now)
        }
        if !isResumingFromSnooze {
            activeScheduleNaturalEnd = computeScheduleEndTime(for: schedule, at: now)
            beginBlock()
        }
        currentBlockScheduleIDs = [schedule.id]

        activeSchedule = schedule
        isBlocking = true
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

    /// Exit the current block early, scheduled or manual (user chose to exit). `blockID` is the block the
    /// request was made for; it's refused if a different block is running by now.
    func exitBlockEarly(blockID: UUID? = nil) {
        checkSchedules()
        guard blockID == nil || blockID == currentBlockID else { return }
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

        clearBlock()
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
            content.body = "\(schedule.displayName) begins in \(Self.describeMinutes(notificationLeadTime))"
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

    /// "1 minute", "5 minutes"
    static func describeMinutes(_ minutes: Int) -> String {
        minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    /// Whether the current block was resumed by hand rather than started by its schedule
    var isManualBlock: Bool {
        manualBlockSchedule != nil
    }

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
