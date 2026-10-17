import Foundation

/// Source of the current time for scheduling and stats logic.
/// Tests replace `now` to drive time deterministically.
enum AppClock {
    static var now: () -> Date = { Date() }
}
