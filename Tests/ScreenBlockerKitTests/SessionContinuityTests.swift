import Foundation
import Testing
@testable import ScreenBlockerKit

/// Whether a new block continues the previous session or starts its own, and where sessions end.
/// Rule: a block continues the previous one if any of its schedules started before the previous block's
/// (possibly snooze-extended) end; otherwise the previous session closes at that end and a new one starts.
@Suite(.serialized)
struct SessionContinuityTests {
    @Test func overlapFirstSeenAfterWakeStaysOneSession() {
        let a = makeSchedule((9, 0), (10, 0), name: "A")
        let b = makeSchedule((9, 30), (11, 0), name: "B")
        let h = Harness(schedules: [a, b])
        h.tick(at: date(2026, 10, 19, 9, 0))
        let sessionID = h.stats.currentSession?.id
        h.sleep(at: date(2026, 10, 19, 9, 15))
        h.wake(at: date(2026, 10, 19, 10, 15))

        #expect(h.manager.isBlocking)
        #expect(h.stats.currentSession?.id == sessionID)
        #expect(h.stats.currentSession?.scheduleName == "B")
        #expect(h.sessionState == .active)
        #expect(h.savedSessions().count == 1)
    }

    @Test func overnightOverlapFirstSeenAfterWakeStaysOneSession() {
        let a = makeSchedule((22, 0), (2, 0), name: "A")
        let b = makeSchedule((1, 0), (3, 0), name: "B")
        let h = Harness(schedules: [a, b])
        h.tick(at: date(2026, 10, 19, 22, 0))
        let sessionID = h.stats.currentSession?.id
        h.sleep(at: date(2026, 10, 19, 23, 0))
        h.wake(at: date(2026, 10, 20, 2, 30))

        #expect(h.stats.currentSession?.id == sessionID)
        #expect(h.stats.currentSession?.scheduleName == "B")
        #expect(h.savedSessions().count == 1)
    }

    @Test func blockRightAfterSnoozeExtendedEndGetsNewSession() {
        let a = makeSchedule((9, 0), (9, 30), name: "A")
        let b = makeSchedule((9, 35), (10, 0), name: "B")
        let h = Harness(schedules: [a, b])
        h.tick(at: date(2026, 10, 19, 9, 0))
        setClock(date(2026, 10, 19, 9, 20))
        h.manager.snooze(minutes: 5) // A now ends 9:35
        h.tick(at: date(2026, 10, 19, 9, 25))
        let sessionA = h.stats.currentSession?.id

        h.tick(at: date(2026, 10, 19, 9, 35))
        #expect(h.manager.isBlocking)
        #expect(h.stats.currentSession?.scheduleName == "B")
        #expect(h.stats.currentSession?.id != sessionA)
        let savedA = h.savedSessions().first { $0.id == sessionA }
        #expect(savedA?.scheduleName == "A")
        #expect(savedA?.endReason == .completed)
        #expect(savedA?.events.last?.timestamp == date(2026, 10, 19, 9, 35))
    }

    @Test func blockAfterGapFollowingSnoozeExtendedEndGetsNewSession() {
        let a = makeSchedule((9, 0), (9, 30), name: "A")
        let b = makeSchedule((9, 40), (10, 0), name: "B")
        let h = Harness(schedules: [a, b])
        h.tick(at: date(2026, 10, 19, 9, 0))
        setClock(date(2026, 10, 19, 9, 20))
        h.manager.snooze(minutes: 5)
        h.tick(at: date(2026, 10, 19, 9, 25))

        h.tick(at: date(2026, 10, 19, 9, 35))
        #expect(!h.manager.isBlocking)
        #expect(h.stats.currentSession == nil)
        #expect(h.savedSessions().last?.endReason == .completed)

        h.tick(at: date(2026, 10, 19, 9, 40))
        #expect(h.stats.currentSession?.scheduleName == "B")
        #expect(h.savedSessions().count == 2)
    }

    @Test func wakeIntoLaterBlockAfterSnoozeExtendedEndGetsNewSession() {
        let a = makeSchedule((9, 0), (9, 30), name: "A")
        let b = makeSchedule((10, 0), (10, 30), name: "B")
        let h = Harness(schedules: [a, b])
        h.tick(at: date(2026, 10, 19, 9, 0))
        setClock(date(2026, 10, 19, 9, 20))
        h.manager.snooze(minutes: 5)
        h.tick(at: date(2026, 10, 19, 9, 25))
        h.sleep(at: date(2026, 10, 19, 9, 30))
        h.wake(at: date(2026, 10, 19, 10, 10))

        #expect(h.stats.currentSession?.scheduleName == "B")
        let savedA = h.savedSessions().first { $0.scheduleName == "A" }
        #expect(savedA?.endReason == .completed)
        #expect(savedA?.events.last?.timestamp == date(2026, 10, 19, 9, 35))
    }

    @Test func longerOverlapStartingDuringSnoozeTakesOverAndStays() {
        let a = makeSchedule((9, 0), (10, 0), name: "A")
        let b = makeSchedule((9, 30), (11, 0), name: "B")
        let h = Harness(schedules: [a, b])
        h.tick(at: date(2026, 10, 19, 9, 0))
        let sessionID = h.stats.currentSession?.id
        setClock(date(2026, 10, 19, 9, 28))
        h.manager.snooze(minutes: 5)

        h.tick(at: date(2026, 10, 19, 9, 33))
        #expect(h.manager.activeSchedule?.name == "B")
        #expect(h.stats.currentSession?.scheduleName == "B")
        #expect(h.stats.currentSession?.id == sessionID)

        h.tick(at: date(2026, 10, 19, 9, 34))
        #expect(h.manager.activeSchedule?.name == "B")
        h.tick(at: date(2026, 10, 19, 10, 30))
        #expect(h.manager.activeSchedule?.name == "B")
        #expect(h.manager.isBlocking)
    }

    @Test func splitOnWakeClosesOldSessionAtItsEnd() {
        let a = makeSchedule((9, 0), (9, 30), name: "A")
        let b = makeSchedule((10, 0), (10, 30), name: "B")
        let h = Harness(schedules: [a, b])
        h.tick(at: date(2026, 10, 19, 9, 0))
        h.sleep(at: date(2026, 10, 19, 9, 10))
        h.wake(at: date(2026, 10, 19, 10, 10))

        let savedA = h.savedSessions().first { $0.scheduleName == "A" }!
        #expect(savedA.events.last?.timestamp == date(2026, 10, 19, 9, 30))
        setClock(date(2026, 10, 19, 12, 0))
        let totals = h.stats.totals(for: savedA, period: .day)
        #expect(totals.active == 10 * 60)
        #expect(totals.sleeping == 20 * 60)
    }

    @Test func sleepingThroughBlockEndClosesSessionAtItsEnd() {
        let h = Harness(schedules: [makeSchedule((9, 0), (9, 30))])
        h.tick(at: date(2026, 10, 19, 9, 0))
        h.sleep(at: date(2026, 10, 19, 9, 10))
        h.wake(at: date(2026, 10, 19, 11, 0))

        #expect(h.savedSessions().last?.events.last?.timestamp == date(2026, 10, 19, 9, 30))
    }

    @Test func overlappingBlocksWhileAwakeStayOneSession() {
        let a = makeSchedule((9, 0), (10, 0), name: "A")
        let b = makeSchedule((9, 45), (10, 30), name: "B")
        let h = Harness(schedules: [a, b])
        h.tick(at: date(2026, 10, 19, 9, 0))
        h.tick(at: date(2026, 10, 19, 9, 45))
        h.tick(at: date(2026, 10, 19, 10, 0))
        h.tick(at: date(2026, 10, 19, 10, 30))

        let saved = h.savedSessions()
        #expect(saved.count == 1)
        #expect(saved.first?.scheduleName == "B")
        #expect(saved.first?.events.last?.timestamp == date(2026, 10, 19, 10, 30))
    }
}

@Suite(.serialized)
struct SnoozeContinuityTests {
    @Test func sleepingThroughSnoozeIntoOverlapKeepsOneSession() {
        let a = makeSchedule((9, 0), (9, 30), name: "A")
        let b = makeSchedule((9, 29), (10, 0), name: "B")
        let h = Harness(schedules: [a, b])
        h.tick(at: date(2026, 10, 19, 9, 0))
        let sessionID = h.stats.currentSession?.id
        setClock(date(2026, 10, 19, 9, 25))
        h.manager.snooze(minutes: 5) // A now ends 9:35
        h.sleep(at: date(2026, 10, 19, 9, 26))
        h.wake(at: date(2026, 10, 19, 9, 40))

        #expect(h.manager.isBlocking)
        #expect(h.stats.currentSession?.id == sessionID)
        #expect(h.stats.currentSession?.scheduleName == "B")
        #expect(h.sessionState == .active)
        #expect(h.savedSessions().count == 1)

        h.tick(at: date(2026, 10, 19, 10, 0))
        setClock(date(2026, 10, 19, 12, 0))
        let session = h.savedSessions().first!
        let totals = h.stats.totals(for: session, period: .day)
        #expect(totals.active == 25 * 60 + 20 * 60)
        #expect(totals.snoozed == 1 * 60)
        #expect(totals.sleeping == 14 * 60)
    }

    @Test func sleepingThroughSnoozePastEndCancelsAtExtendedEnd() {
        let a = makeSchedule((9, 0), (9, 30), name: "A")
        let h = Harness(schedules: [a])
        h.tick(at: date(2026, 10, 19, 9, 0))
        setClock(date(2026, 10, 19, 9, 25))
        h.manager.snooze(minutes: 5)
        h.sleep(at: date(2026, 10, 19, 9, 26))
        h.wake(at: date(2026, 10, 19, 9, 40))

        #expect(!h.manager.isBlocking)
        #expect(h.stats.currentSession == nil)
        let saved = h.savedSessions().first
        #expect(saved?.endReason == .cancelled)
        #expect(saved?.events.last?.timestamp == date(2026, 10, 19, 9, 35))
    }

    @Test func snoozedOwnerAcrossMidnightLosesToLaterEndingOverlap() {
        let a = makeSchedule((23, 0), (23, 58), name: "A")
        let b = makeSchedule((0, 0), (0, 10), name: "B")
        let h = Harness(schedules: [a, b])
        h.tick(at: date(2026, 10, 19, 23, 0))
        setClock(date(2026, 10, 19, 23, 56))
        h.manager.snooze(minutes: 5) // A now ends 00:03

        h.tick(at: date(2026, 10, 20, 0, 1))
        #expect(h.manager.activeSchedule?.name == "B")
        #expect(h.stats.currentSession?.scheduleName == "B")
        #expect(h.manager.currentBlockEndTime == date(2026, 10, 20, 0, 10))
        h.tick(at: date(2026, 10, 20, 0, 2))
        #expect(h.manager.activeSchedule?.name == "B")
    }
}
