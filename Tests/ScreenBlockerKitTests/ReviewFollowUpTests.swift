import Foundation
import Testing
@testable import ScreenBlockerKit

/// Cases raised in the follow-up review of the fixes.
@Suite(.serialized)
struct ReviewFollowUpTests {
    @Test func repeatedUnreadableFilesInSameSecondAreAllPreserved() throws {
        let h = Harness(schedules: [makeSchedule((9, 0), (9, 30))])
        let url = h.statsDirectory.appendingPathComponent("2026-10.json")
        let first = Data("[{first broken".utf8)
        let second = Data("[{second broken".utf8)

        try first.write(to: url)
        h.tick(at: date(2026, 10, 19, 9, 0))
        // Same second as the first save, so timestamp-only backup names would collide
        try second.write(to: url)
        h.manager.snooze(minutes: 5)

        let files = try FileManager.default.contentsOfDirectory(at: h.statsDirectory, includingPropertiesForKeys: nil)
        let contents = files.compactMap { try? Data(contentsOf: $0) }
        #expect(contents.contains(first))
        #expect(contents.contains(second))
    }

    @Test func deletingSnoozedResumedBlockCancelsIt() {
        let schedule = makeSchedule((9, 0), (10, 0))
        let h = Harness(schedules: [schedule])
        h.tick(at: date(2026, 10, 19, 9, 0))
        setClock(date(2026, 10, 19, 9, 5))
        h.manager.exitBlockEarly()
        setClock(date(2026, 10, 19, 9, 10))
        h.manager.startManualBlock(from: schedule)
        setClock(date(2026, 10, 19, 9, 11))
        h.manager.snooze(minutes: 5)
        h.manager.deleteSchedule(schedule)

        h.tick(at: date(2026, 10, 19, 9, 17))
        #expect(!h.manager.isBlocking)
        #expect(!h.overlay.isShown)
        #expect(h.stats.currentSession == nil)
        #expect(h.savedSessions().last?.endReason == .cancelled)
    }

    @Test func cannotResumeSnoozedScheduleAfterDisablingIt() {
        var schedule = makeSchedule((9, 0), (10, 0))
        let h = Harness(schedules: [schedule])
        h.tick(at: date(2026, 10, 19, 9, 0))
        setClock(date(2026, 10, 19, 9, 1))
        h.manager.snooze(minutes: 5)

        schedule.isEnabled = false
        h.manager.updateSchedule(schedule)
        #expect(!h.manager.canResume(schedule))
    }
}
