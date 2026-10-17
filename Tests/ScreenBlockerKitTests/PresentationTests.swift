import Foundation
import Testing
@testable import ScreenBlockerKit

@Suite(.serialized)
struct PresentationTests {
    @Test func weekdaysStartOnCalendarFirstDay() {
        let ordered = Weekday.orderedForCurrentCalendar
        #expect(ordered.count == 7)
        #expect(Set(ordered) == Set(Weekday.allCases))
        #expect(ordered.first?.rawValue == Calendar.current.firstWeekday)
    }

    @Test func blankNameFallsBack() {
        #expect(makeSchedule((9, 0), (9, 30), name: "  ").displayName == "Untitled")
        #expect(makeSchedule((9, 0), (9, 30), name: "Lunch").displayName == "Lunch")
    }

    @Test func notificationBodyUsesSingularMinute() {
        let schedule = makeSchedule((9, 0), (9, 30), name: "Lunch")
        let h = Harness()
        h.manager.notificationLeadTime = 1
        setClock(date(2026, 10, 19, 8, 0))
        h.manager.schedules = [schedule]
        h.manager.saveSchedules()
        #expect(h.notifications.pending["block-\(schedule.id.uuidString)"]?.content.body == "Lunch begins in 1 minute")
    }
}
