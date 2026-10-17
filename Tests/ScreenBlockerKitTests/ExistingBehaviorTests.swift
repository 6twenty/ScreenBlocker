import Foundation
import Testing
@testable import ScreenBlockerKit

/// Characterization tests: pin down behaviour that already works, so fixes elsewhere can't regress it.
@Suite(.serialized)
struct ExistingBehaviorTests {
    @Test func scheduledBlockStartsAndCompletes() {
        let h = Harness(schedules: [makeSchedule((9, 0), (9, 30))])

        h.tick(at: date(2026, 10, 19, 8, 59, 59))
        #expect(!h.manager.isBlocking)
        #expect(!h.overlay.isShown)

        h.tick(at: date(2026, 10, 19, 9, 0))
        #expect(h.manager.isBlocking)
        #expect(!h.manager.isManualBlock)
        #expect(h.overlay.isShown)
        #expect(h.manager.currentBlockEndTime == date(2026, 10, 19, 9, 30))
        #expect(h.sessionState == .active)
        #expect(h.stats.currentSession?.scheduleName == "Break")

        h.tick(at: date(2026, 10, 19, 9, 30))
        #expect(!h.manager.isBlocking)
        #expect(!h.overlay.isShown)
        #expect(h.stats.currentSession == nil)

        let saved = h.savedSessions()
        #expect(saved.count == 1)
        #expect(saved.first?.endReason == .completed)
    }

    @Test func disabledScheduleNeverBlocks() {
        let h = Harness(schedules: [makeSchedule((9, 0), (9, 30), enabled: false)])
        h.tick(at: date(2026, 10, 19, 9, 10))
        #expect(!h.manager.isBlocking)
    }

    @Test func weekdayFilterIsRespected() {
        let h = Harness(schedules: [makeSchedule((9, 0), (9, 30), days: [.tuesday])])
        h.tick(at: date(2026, 10, 19, 9, 10)) // Monday
        #expect(!h.manager.isBlocking)
        h.tick(at: date(2026, 10, 20, 9, 10)) // Tuesday
        #expect(h.manager.isBlocking)
    }

    @Test func overnightBlockBelongsToItsStartDay() {
        // Friday 22:00 → Saturday 02:00
        let schedule = makeSchedule((22, 0), (2, 0), days: [.friday])
        #expect(schedule.isActive(at: date(2026, 10, 23, 23, 0)))   // Fri 23:00
        #expect(schedule.isActive(at: date(2026, 10, 24, 1, 0)))    // Sat 01:00
        #expect(!schedule.isActive(at: date(2026, 10, 24, 23, 0)))  // Sat 23:00
        #expect(!schedule.isActive(at: date(2026, 10, 23, 1, 0)))   // Fri 01:00 (Thursday's night)

        let h = Harness(schedules: [schedule])
        h.tick(at: date(2026, 10, 23, 22, 0))
        #expect(h.manager.isBlocking)
        #expect(h.manager.currentBlockEndTime == date(2026, 10, 24, 2, 0))
        h.tick(at: date(2026, 10, 24, 2, 0))
        #expect(!h.manager.isBlocking)
    }

    @Test func snoozeHidesThenResumesWithExtendedEnd() {
        let h = Harness(schedules: [makeSchedule((9, 0), (9, 30))])
        h.tick(at: date(2026, 10, 19, 9, 0))

        setClock(date(2026, 10, 19, 9, 2))
        h.manager.snooze(minutes: 5)
        #expect(!h.manager.isBlocking)
        #expect(h.manager.isSnoozed)
        #expect(!h.overlay.isShown)
        #expect(h.sessionState == .snoozed)
        #expect(h.manager.currentBlockEndTime == date(2026, 10, 19, 9, 35))

        h.tick(at: date(2026, 10, 19, 9, 6))
        #expect(!h.manager.isBlocking)

        h.tick(at: date(2026, 10, 19, 9, 7))
        #expect(h.manager.isBlocking)
        #expect(h.overlay.isShown)
        #expect(h.sessionState == .active)
        #expect(h.manager.currentBlockEndTime == date(2026, 10, 19, 9, 35))

        // Still blocking after the schedule's natural end, until the extended end
        h.tick(at: date(2026, 10, 19, 9, 31))
        #expect(h.manager.isBlocking)
        h.tick(at: date(2026, 10, 19, 9, 35))
        #expect(!h.manager.isBlocking)
        #expect(h.savedSessions().last?.endReason == .completed)
    }

    @Test func exitEarlySuppressesUntilNaturalEnd() {
        let h = Harness(schedules: [makeSchedule((9, 0), (9, 30))])
        h.tick(at: date(2026, 10, 19, 9, 0))

        setClock(date(2026, 10, 19, 9, 5))
        h.manager.exitBlockEarly()
        #expect(!h.manager.isBlocking)
        #expect(!h.overlay.isShown)
        #expect(h.savedSessions().last?.endReason == .exited)

        h.tick(at: date(2026, 10, 19, 9, 6))
        #expect(!h.manager.isBlocking)

        h.tick(at: date(2026, 10, 20, 9, 0))
        #expect(h.manager.isBlocking)
    }

    @Test func manualBlockRunsUntilScheduleEnd() {
        let schedule = makeSchedule((9, 0), (12, 0), enabled: false)
        let h = Harness(schedules: [schedule])

        setClock(date(2026, 10, 19, 11, 0))
        h.manager.startManualBlock(from: schedule)
        #expect(h.manager.isBlocking)
        #expect(h.manager.isManualBlock)
        #expect(h.overlay.isShown)
        #expect(h.manager.currentBlockEndTime == date(2026, 10, 19, 12, 0))
        #expect(h.sessionState == .active)

        h.tick(at: date(2026, 10, 19, 11, 30))
        #expect(h.manager.isBlocking)

        h.tick(at: date(2026, 10, 19, 12, 0))
        #expect(!h.manager.isBlocking)
        #expect(!h.manager.isManualBlock)
        #expect(h.savedSessions().last?.endReason == .completed)
    }

    @Test func manualBlockStopRecordsExit() {
        let schedule = makeSchedule((9, 0), (12, 0))
        let h = Harness(schedules: [schedule])
        h.tick(at: date(2026, 10, 19, 9, 0))

        setClock(date(2026, 10, 19, 9, 1))
        h.manager.stopManualBlock()
        #expect(!h.manager.isBlocking)
        #expect(h.savedSessions().last?.endReason == .exited)

        // Exited schedule doesn't immediately re-trigger
        h.tick(at: date(2026, 10, 19, 9, 2))
        #expect(!h.manager.isBlocking)
    }

    @Test func sleepThroughBlockEndCompletesSession() {
        let h = Harness(schedules: [makeSchedule((9, 0), (9, 30))])
        h.tick(at: date(2026, 10, 19, 9, 0))
        h.sleep(at: date(2026, 10, 19, 9, 10))
        #expect(h.sessionState == .sleeping)

        h.wake(at: date(2026, 10, 19, 10, 0))
        #expect(!h.manager.isBlocking)
        #expect(h.stats.currentSession == nil)
        #expect(h.savedSessions().last?.endReason == .completed)
    }

    @Test func sleepDuringSnoozeResumesAsSnoozed() {
        let h = Harness(schedules: [makeSchedule((9, 0), (9, 30))])
        h.tick(at: date(2026, 10, 19, 9, 0))
        setClock(date(2026, 10, 19, 9, 1))
        h.manager.snooze(minutes: 10)

        h.sleep(at: date(2026, 10, 19, 9, 2))
        #expect(h.sessionState == .sleeping)
        h.wake(at: date(2026, 10, 19, 9, 5))
        #expect(h.sessionState == .snoozed)
        #expect(!h.manager.isBlocking)
    }

    @Test func sleepThenWakeIntoResumedSnoozeIsActive() {
        let h = Harness(schedules: [makeSchedule((9, 0), (9, 30))])
        h.tick(at: date(2026, 10, 19, 9, 0))
        setClock(date(2026, 10, 19, 9, 1))
        h.manager.snooze(minutes: 5)
        h.sleep(at: date(2026, 10, 19, 9, 2))

        h.wake(at: date(2026, 10, 19, 9, 10))
        #expect(h.manager.isBlocking)
        #expect(h.sessionState == .active)
    }

    @Test func statsTotalsSplitByState() {
        let h = Harness(schedules: [makeSchedule((9, 0), (9, 30))])
        h.tick(at: date(2026, 10, 19, 9, 0))
        setClock(date(2026, 10, 19, 9, 10))
        h.manager.snooze(minutes: 5)
        h.tick(at: date(2026, 10, 19, 9, 15))
        h.tick(at: date(2026, 10, 19, 9, 35))

        setClock(date(2026, 10, 19, 12, 0))
        let totals = h.stats.totals(for: .day)
        #expect(totals.active == 30 * 60)
        #expect(totals.snoozed == 5 * 60)
        #expect(totals.sleeping == 0)
    }

    @Test func notificationScheduledAtLeadTime() {
        let schedule = makeSchedule((9, 0), (9, 30))
        let h = Harness()
        h.manager.notificationLeadTime = 5
        setClock(date(2026, 10, 19, 8, 0))
        h.manager.schedules = [schedule]
        h.manager.saveSchedules()

        #expect(h.notifications.fireDate(for: schedule) == date(2026, 10, 19, 8, 55))
    }

    @Test func schedulesPersistAcrossInstances() {
        let schedule = makeSchedule((12, 0), (13, 0), name: "Lunch")
        let h = Harness(schedules: [schedule])
        let reloaded = ScheduleManager(
            defaults: h.defaults, stats: h.stats, overlay: FakeOverlay(), notificationCenter: FakeNotificationCenter()
        )
        #expect(reloaded.schedules == [schedule])
    }

    @Test func legacyScheduleWithoutMessageDecodes() throws {
        let json = """
        [{"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","name":"Old","startHour":9,"startMinute":0,
          "endHour":10,"endMinute":0,"enabledDays":[2,3],"isEnabled":true}]
        """
        let schedules = try JSONDecoder().decode([Schedule].self, from: Data(json.utf8))
        #expect(schedules.first?.message == "")
        #expect(schedules.first?.enabledDays == [.monday, .tuesday])
    }
}
