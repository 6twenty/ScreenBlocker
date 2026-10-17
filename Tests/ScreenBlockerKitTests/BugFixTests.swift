import Foundation
import Testing
@testable import ScreenBlockerKit

@Suite(.serialized)
struct WakeHandlingTests {
    @Test func wakeDuringScheduledBlockResumesActive() {
        let h = Harness(schedules: [makeSchedule((9, 0), (9, 30))])
        h.tick(at: date(2026, 10, 19, 9, 0))
        h.sleep(at: date(2026, 10, 19, 9, 10))
        h.wake(at: date(2026, 10, 19, 9, 20))

        #expect(h.manager.isBlocking)
        #expect(h.sessionState == .active)

        h.tick(at: date(2026, 10, 19, 9, 30))
        setClock(date(2026, 10, 19, 12, 0))
        let totals = h.stats.totals(for: .day)
        #expect(totals.active == 20 * 60)
        #expect(totals.sleeping == 10 * 60)
    }

    @Test func wakeDuringManualBlockResumesActive() {
        let schedule = makeSchedule((9, 0), (12, 0))
        let h = Harness(schedules: [schedule])
        h.tick(at: date(2026, 10, 19, 9, 0))
        setClock(date(2026, 10, 19, 9, 30))
        h.manager.exitBlockEarly()
        setClock(date(2026, 10, 19, 10, 0))
        h.manager.startManualBlock(from: schedule)
        #expect(h.manager.isManualBlock)
        h.sleep(at: date(2026, 10, 19, 10, 10))
        h.wake(at: date(2026, 10, 19, 10, 20))

        #expect(h.manager.isBlocking)
        #expect(h.sessionState == .active)
    }

    @Test func wakeIntoNewBlockStartsSession() {
        let h = Harness(schedules: [makeSchedule((9, 0), (10, 0))])
        h.tick(at: date(2026, 10, 19, 8, 50))
        h.sleep(at: date(2026, 10, 19, 8, 55))
        h.wake(at: date(2026, 10, 19, 9, 10))

        #expect(h.manager.isBlocking)
        #expect(h.sessionState == .active)
        #expect(h.stats.currentSession?.scheduleName == "Break")
    }

    @Test func wakeWhenManualSnoozeExpiredDuringSleepResumesActive() {
        let schedule = makeSchedule((9, 0), (12, 0))
        let h = Harness(schedules: [schedule])
        h.tick(at: date(2026, 10, 19, 9, 0))
        setClock(date(2026, 10, 19, 9, 30))
        h.manager.exitBlockEarly()
        setClock(date(2026, 10, 19, 10, 0))
        h.manager.startManualBlock(from: schedule)
        #expect(h.manager.isManualBlock)
        h.manager.snooze(minutes: 5)
        h.sleep(at: date(2026, 10, 19, 10, 1))
        h.wake(at: date(2026, 10, 19, 10, 30))

        #expect(h.manager.isBlocking)
        #expect(h.sessionState == .active)
    }
}

@Suite(.serialized)
struct QuitAndRecoveryTests {
    @Test func terminatingMidBlockClosesSession() {
        let h = Harness(schedules: [makeSchedule((9, 0), (9, 30))])
        h.tick(at: date(2026, 10, 19, 9, 0))

        setClock(date(2026, 10, 19, 9, 10))
        h.manager.handleAppTermination()

        #expect(h.stats.currentSession == nil)
        let saved = h.savedSessions()
        #expect(saved.count == 1)
        #expect(saved.first?.endReason == .cancelled)
        #expect(saved.first?.events.last?.timestamp == date(2026, 10, 19, 9, 10))
    }

    @Test func recoveryDoesNotCountTimeWhileAppWasGone() {
        let h = Harness(schedules: [makeSchedule((9, 0), (9, 30))])
        h.tick(at: date(2026, 10, 19, 9, 0))
        // Crash: no termination handling. Relaunch the next day.
        setClock(date(2026, 10, 20, 9, 0))
        _ = StatsManager(statsDirectory: h.statsDirectory)

        let saved = h.savedSessions()
        #expect(saved.count == 1)
        #expect(saved.first?.endReason == .error)

        let recovered = StatsManager(statsDirectory: h.statsDirectory)
        setClock(date(2026, 10, 19, 23, 0))
        #expect(recovered.totals(for: .day).active < 60 * 60)
    }

    @Test func recoveryFindsOrphansInOlderMonths() {
        let h = Harness(schedules: [makeSchedule((9, 0), (9, 30))])
        h.tick(at: date(2026, 6, 1, 9, 0))

        setClock(date(2026, 10, 20, 9, 0))
        _ = StatsManager(statsDirectory: h.statsDirectory)

        #expect(h.savedSessions().first?.endReason == .error)
    }
}

@Suite(.serialized)
struct CorruptDataTests {
    @Test func unreadableStatsFileIsPreserved() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenBlockerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let garbage = Data("[{not valid json".utf8)
        try garbage.write(to: directory.appendingPathComponent("2026-10.json"))

        let h = Harness(schedules: [makeSchedule((9, 0), (9, 30))], statsDirectory: directory)
        h.tick(at: date(2026, 10, 19, 9, 0))

        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let preserved = files.contains { (try? Data(contentsOf: $0)) == garbage }
        #expect(preserved)
        #expect(h.savedSessions().count == 1)
    }

    @Test func undecodableSchedulesAreBackedUpNotOverwritten() {
        let suite = "ScreenBlockerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let garbage = Data("not schedules".utf8)
        defaults.set(garbage, forKey: "ScreenBlocker.schedules")

        let stats = StatsManager(statsDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenBlockerTests-\(UUID().uuidString)"))
        let manager = ScheduleManager(
            defaults: defaults, stats: stats, overlay: FakeOverlay(), notificationCenter: FakeNotificationCenter()
        )
        #expect(manager.schedules.isEmpty)

        manager.addSchedule(makeSchedule((9, 0), (9, 30)))
        #expect(defaults.data(forKey: "ScreenBlocker.schedules.unreadableBackup") == garbage)
    }
}

@Suite(.serialized)
struct SnoozeEdgeCaseTests {
    @Test func deletingSnoozedScheduleClosesSession() {
        let schedule = makeSchedule((9, 0), (10, 0))
        let h = Harness(schedules: [schedule])
        h.tick(at: date(2026, 10, 19, 9, 0))
        setClock(date(2026, 10, 19, 9, 1))
        h.manager.snooze(minutes: 5)
        h.manager.deleteSchedule(schedule)

        h.tick(at: date(2026, 10, 19, 9, 6))
        #expect(!h.manager.isBlocking)
        #expect(h.stats.currentSession == nil)
        #expect(h.savedSessions().last?.endReason == .cancelled)

        h.tick(at: date(2026, 10, 19, 10, 6))
        #expect(h.stats.currentSession == nil)
    }

    @Test func startingAnotherScheduleDuringSnoozeStartsFreshSession() {
        // A ends last, so it names the combined block; B is in its window but suppressed by the snooze
        let a = makeSchedule((9, 0), (10, 0), name: "A")
        let b = makeSchedule((9, 0), (9, 45), name: "B")
        let h = Harness(schedules: [a, b])
        h.tick(at: date(2026, 10, 19, 9, 0))
        setClock(date(2026, 10, 19, 9, 1))
        h.manager.snooze(minutes: 5)

        setClock(date(2026, 10, 19, 9, 2))
        h.manager.startManualBlock(from: b)

        #expect(h.manager.activeSchedule?.name == "B")
        #expect(h.stats.currentSession?.scheduleName == "B")
        #expect(h.sessionState == .active)
        #expect(h.savedSessions().first { $0.scheduleName == "A" }?.endReason == .cancelled)
    }

    @Test func resumingSameScheduleDuringSnoozeKeepsSessionAndExtendedEnd() {
        let schedule = makeSchedule((9, 0), (10, 0))
        let h = Harness(schedules: [schedule])
        h.tick(at: date(2026, 10, 19, 9, 0))
        setClock(date(2026, 10, 19, 9, 1))
        h.manager.snooze(minutes: 5)
        let sessionID = h.stats.currentSession?.id

        setClock(date(2026, 10, 19, 9, 2))
        h.manager.startManualBlock(from: schedule)

        #expect(h.stats.currentSession?.id == sessionID)
        #expect(h.sessionState == .active)
        #expect(h.manager.currentBlockEndTime == date(2026, 10, 19, 10, 5))
    }
}

@Suite(.serialized)
struct NotificationReplenishTests {
    @Test func nextOccurrenceQueuedAfterBlockStarts() {
        let schedule = makeSchedule((9, 0), (9, 30))
        let h = Harness()
        h.manager.notificationLeadTime = 5
        setClock(date(2026, 10, 19, 8, 0))
        h.manager.schedules = [schedule]
        h.manager.saveSchedules()
        h.tick(at: date(2026, 10, 19, 8, 0))
        #expect(h.notifications.fireDate(for: schedule) == date(2026, 10, 19, 8, 55))

        h.tick(at: date(2026, 10, 19, 9, 0))
        #expect(h.notifications.fireDate(for: schedule) == date(2026, 10, 20, 8, 55))
    }

    @Test func occurrencesBeyondADayAreQueued() {
        let schedule = makeSchedule((9, 0), (9, 30), days: [.wednesday])
        let h = Harness()
        h.manager.notificationLeadTime = 5
        setClock(date(2026, 10, 19, 8, 0)) // Monday
        h.manager.schedules = [schedule]
        h.manager.saveSchedules()

        #expect(h.notifications.fireDate(for: schedule) == date(2026, 10, 21, 8, 55))
    }
}

@Suite(.serialized)
struct StatsQueryTests {
    @Test func openOvernightSessionAppearsInToday() {
        let schedule = makeSchedule((23, 0), (1, 0))
        let h = Harness(schedules: [schedule])
        h.tick(at: date(2026, 10, 19, 23, 0))

        setClock(date(2026, 10, 20, 0, 30))
        #expect(h.stats.sessions(for: .day).count == 1)
        #expect(h.stats.totals(for: .day).active == 30 * 60)
    }

    @Test func sessionTotalsAreClampedToPeriod() {
        let schedule = makeSchedule((23, 0), (1, 0))
        let h = Harness(schedules: [schedule])
        h.tick(at: date(2026, 10, 19, 23, 0))
        h.tick(at: date(2026, 10, 20, 1, 0))

        setClock(date(2026, 10, 20, 12, 0))
        let session = h.stats.sessions(for: .day).first!
        #expect(h.stats.totals(for: session, period: .day).active == 60 * 60)
        #expect(h.stats.totals(for: session, period: .day, offset: -1).active == 60 * 60)
    }
}
