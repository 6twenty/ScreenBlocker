import Foundation
import Testing
@testable import ScreenBlockerKit

/// Behaviour agreed in review: Resume only within a schedule's time, overlaps act as one block.
@Suite(.serialized)
struct ResumeTests {
    @Test func cannotResumeOutsideScheduledTime() {
        let schedule = makeSchedule((9, 0), (9, 30))
        let h = Harness(schedules: [schedule])
        setClock(date(2026, 10, 19, 10, 0))

        #expect(!h.manager.canResume(schedule))
        h.manager.startManualBlock(from: schedule)
        #expect(!h.manager.isBlocking)
        #expect(h.stats.currentSession == nil)
    }

    @Test func cannotResumeDisabledSchedule() {
        let schedule = makeSchedule((9, 0), (12, 0), enabled: false)
        let h = Harness(schedules: [schedule])
        setClock(date(2026, 10, 19, 10, 0))
        #expect(!h.manager.canResume(schedule))
    }

    @Test func resumeInLastMinuteEndsToday() {
        let schedule = makeSchedule((9, 0), (9, 30))
        let h = Harness(schedules: [schedule])
        h.tick(at: date(2026, 10, 19, 9, 0))
        setClock(date(2026, 10, 19, 9, 1))
        h.manager.exitBlockEarly()

        setClock(date(2026, 10, 19, 9, 29, 30))
        h.manager.startManualBlock(from: schedule)
        #expect(h.manager.currentBlockEndTime == date(2026, 10, 19, 9, 30))
    }

    @Test func resumeOvernightAfterMidnightEndsThatMorning() {
        let schedule = makeSchedule((22, 0), (2, 0))
        let h = Harness(schedules: [schedule])
        h.tick(at: date(2026, 10, 19, 22, 0))
        setClock(date(2026, 10, 19, 22, 30))
        h.manager.exitBlockEarly()

        setClock(date(2026, 10, 20, 1, 0))
        h.manager.startManualBlock(from: schedule)
        #expect(h.manager.currentBlockEndTime == date(2026, 10, 20, 2, 0))
    }

    @Test func canResumeSnoozedBlockAfterItsNaturalEnd() {
        let schedule = makeSchedule((9, 0), (9, 30))
        let h = Harness(schedules: [schedule])
        h.tick(at: date(2026, 10, 19, 9, 0))
        setClock(date(2026, 10, 19, 9, 28))
        h.manager.snooze(minutes: 5)

        setClock(date(2026, 10, 19, 9, 31))
        #expect(h.manager.canResume(schedule))
        h.manager.startManualBlock(from: schedule)
        #expect(h.manager.isBlocking)
        #expect(h.manager.currentBlockEndTime == date(2026, 10, 19, 9, 35))
    }
}

@Suite(.serialized)
struct OverlapTests {
    @Test func combinedBlockIsNamedAfterScheduleEndingLast() {
        let long = makeSchedule((9, 0), (11, 0), name: "Long")
        let short = makeSchedule((9, 0), (10, 0), name: "Short")
        let h = Harness(schedules: [long, short])
        h.tick(at: date(2026, 10, 19, 9, 0))

        #expect(h.manager.activeSchedule?.name == "Long")
        #expect(h.manager.currentBlockEndTime == date(2026, 10, 19, 11, 0))
    }

    @Test func laterStartingOverlapKeepsIdentityIfItEndsSooner() {
        let long = makeSchedule((9, 0), (11, 0), name: "Long")
        let inner = makeSchedule((9, 30), (10, 0), name: "Inner")
        let h = Harness(schedules: [long, inner])
        h.tick(at: date(2026, 10, 19, 9, 0))
        h.tick(at: date(2026, 10, 19, 9, 30))

        #expect(h.manager.activeSchedule?.name == "Long")
        #expect(h.stats.currentSession?.scheduleName == "Long")
    }

    @Test func exitingEndsTheWholeCombinedBlock() {
        let long = makeSchedule((9, 0), (11, 0), name: "Long")
        let short = makeSchedule((9, 0), (10, 0), name: "Short")
        let h = Harness(schedules: [long, short])
        h.tick(at: date(2026, 10, 19, 9, 0))

        setClock(date(2026, 10, 19, 9, 5))
        h.manager.exitBlockEarly()
        h.tick(at: date(2026, 10, 19, 9, 6))
        #expect(!h.manager.isBlocking)
        h.tick(at: date(2026, 10, 19, 10, 30))
        #expect(!h.manager.isBlocking)

        // A schedule that starts after the exit still blocks as normal
        let later = makeSchedule((10, 45), (11, 30), name: "Later")
        h.manager.schedules.append(later)
        h.tick(at: date(2026, 10, 19, 10, 45))
        #expect(h.manager.isBlocking)
        #expect(h.manager.activeSchedule?.name == "Later")
    }
}
