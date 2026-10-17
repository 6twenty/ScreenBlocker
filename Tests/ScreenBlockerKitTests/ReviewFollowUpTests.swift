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
}
