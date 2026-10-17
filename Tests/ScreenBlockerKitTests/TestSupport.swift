import Foundation
import UserNotifications
@testable import ScreenBlockerKit

final class FakeOverlay: OverlayPresenting {
    private(set) var isShown = false
    private(set) var showCount = 0

    func showOverlay() {
        isShown = true
        showCount += 1
    }

    func hideOverlay() {
        isShown = false
    }

    func ensureOverlayVisible() {}
}

final class FakeNotificationCenter: NotificationScheduling {
    private(set) var pending: [String: UNNotificationRequest] = [:]
    var delivered: [String] = []

    func add(_ request: UNNotificationRequest) {
        pending[request.identifier] = request
    }

    func removeAllPendingNotificationRequests() {
        pending.removeAll()
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        identifiers.forEach { pending.removeValue(forKey: $0) }
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        delivered.removeAll { identifiers.contains($0) }
    }

    func getDeliveredNotificationIdentifiers(completion: @escaping ([String]) -> Void) {
        completion(delivered)
    }

    /// The trigger's specified date (not nextTriggerDate(), which depends on the real clock)
    func fireDate(for schedule: Schedule) -> Date? {
        guard let trigger = pending["block-\(schedule.id.uuidString)"]?.trigger as? UNCalendarNotificationTrigger,
              !trigger.repeats else { return nil }
        return Calendar.current.date(from: trigger.dateComponents)
    }
}

/// Builds a local date. 2026-10-19 is a Monday.
func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
    Calendar.current.date(from: DateComponents(
        year: year, month: month, day: day, hour: hour, minute: minute, second: second
    ))!
}

func setClock(_ value: Date) {
    AppClock.now = { value }
}

func makeSchedule(
    _ start: (Int, Int),
    _ end: (Int, Int),
    name: String = "Break",
    days: Set<Weekday> = Set(Weekday.allCases),
    enabled: Bool = true
) -> Schedule {
    Schedule(
        name: name,
        startHour: start.0, startMinute: start.1,
        endHour: end.0, endMinute: end.1,
        enabledDays: days,
        isEnabled: enabled
    )
}

/// A ScheduleManager wired to fakes, isolated defaults, and a temporary stats directory.
final class Harness {
    let manager: ScheduleManager
    let stats: StatsManager
    let overlay = FakeOverlay()
    let notifications = FakeNotificationCenter()
    let statsDirectory: URL
    let defaults: UserDefaults
    private let suiteName: String

    init(schedules: [Schedule] = [], statsDirectory: URL? = nil) {
        suiteName = "ScreenBlockerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        self.statsDirectory = statsDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenBlockerTests-\(UUID().uuidString)", isDirectory: true)
        stats = StatsManager(statsDirectory: self.statsDirectory)
        manager = ScheduleManager(defaults: defaults, stats: stats, overlay: overlay, notificationCenter: notifications)
        if !schedules.isEmpty {
            manager.schedules = schedules
            manager.saveSchedules()
        }
    }

    /// Advance the clock and run one monitoring tick.
    func tick(at time: Date) {
        setClock(time)
        manager.checkSchedules()
    }

    func sleep(at time: Date) {
        setClock(time)
        manager.handleSystemSleep()
    }

    func wake(at time: Date) {
        setClock(time)
        manager.handleSystemWake()
    }

    var sessionState: BlockState? {
        stats.currentSession?.currentState
    }

    /// All sessions persisted across the stats directory.
    func savedSessions() -> [BlockSession] {
        let files = (try? FileManager.default.contentsOfDirectory(at: statsDirectory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .flatMap { url -> [BlockSession] in
                guard let data = try? Data(contentsOf: url) else { return [] }
                return (try? JSONDecoder().decode([BlockSession].self, from: data)) ?? []
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: statsDirectory)
    }
}
