import Foundation
import Testing
@testable import ScreenBlockerKit

/// Overlapping schedules act as one combined block.
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
