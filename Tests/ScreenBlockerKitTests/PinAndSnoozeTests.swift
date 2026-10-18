import Foundation
import Testing
@testable import ScreenBlockerKit

@Suite(.serialized)
struct PinLockTests {
    private func makeLock() -> (PinLock, UserDefaults) {
        let defaults = UserDefaults(suiteName: "ScreenBlockerTests.\(UUID().uuidString)")!
        return (PinLock(defaults: defaults), defaults)
    }

    @Test func pinFormat() {
        #expect(PinLock.isValidPin("1234"))
        #expect(PinLock.isValidPin("0042"))
        #expect(PinLock.isValidPin("12345678"))
        #expect(!PinLock.isValidPin("123"))
        #expect(!PinLock.isValidPin("123456789"))
        #expect(!PinLock.isValidPin("12a4"))
        #expect(!PinLock.isValidPin("١٢٣٤"))  // Non-ASCII digits
        #expect(!PinLock.isValidPin("1️⃣2️⃣3️⃣4️⃣"))
        #expect(!PinLock.isValidPin("1\u{0301}234"))  // Combining accent on a digit
    }

    @Test func enableVerifyAndDisable() {
        let (lock, defaults) = makeLock()
        #expect(!lock.isEnabled)
        #expect(lock.enable(pin: "0042"))
        #expect(lock.isEnabled)
        #expect(lock.verify("0042"))
        #expect(!lock.verify("42"))

        // Persists, as a hash rather than the PIN
        let reloaded = PinLock(defaults: defaults)
        #expect(reloaded.isEnabled)
        #expect(reloaded.verify("0042"))
        let stored = defaults.data(forKey: PinLock.credentialKey).map { String(decoding: $0, as: UTF8.self) } ?? ""
        #expect(!stored.contains("0042"))

        // Turning it off takes unlocked Settings, which takes the PIN
        #expect(!lock.disable())
        #expect(lock.isEnabled)
        #expect(!lock.unlockSettings(pin: "1111", since: lock.lockGeneration))
        #expect(lock.unlockSettings(pin: "0042", since: lock.lockGeneration))
        #expect(lock.disable())
        #expect(!lock.isEnabled)
        #expect(!lock.isSettingsUnlocked)
        #expect(!PinLock(defaults: defaults).isEnabled)
    }

    @Test func lockingAgainStopsTheDisable() {
        let (lock, _) = makeLock()
        lock.enable(pin: "1234")
        lock.unlockSettings(pin: "1234", since: lock.lockGeneration)
        lock.lockSettings()
        #expect(!lock.disable())
        #expect(lock.isEnabled)
    }

    @Test func anUnlockFromBeforeTurningThePinOffAndOnDoesNotCarryOver() {
        let (lock, _) = makeLock()
        lock.enable(pin: "1111")
        let generation = lock.lockGeneration
        lock.unlockSettings(pin: "1111", since: generation)
        lock.disable()
        lock.enable(pin: "2222")
        #expect(!lock.unlockSettings(pin: "2222", since: generation))
        #expect(!lock.canEditSettings)
    }

    @Test func cannotReplacePinWithoutTurningItOff() {
        let (lock, _) = makeLock()
        lock.enable(pin: "1111")
        #expect(!lock.enable(pin: "2222"))
        #expect(lock.verify("1111"))
    }

    @Test func unreadableRecordStaysLocked() {
        let (_, defaults) = makeLock()
        defaults.set(Data("garbage".utf8), forKey: PinLock.credentialKey)
        let lock = PinLock(defaults: defaults)
        #expect(lock.isEnabled)
        #expect(!lock.verify("1234"))
        #expect(!lock.disable())
    }

    @Test func unlockFailsIfLockedWhilePromptWasOpen() {
        let (lock, _) = makeLock()
        lock.enable(pin: "1234")
        let generation = lock.lockGeneration
        lock.lockSettings()  // e.g. a block started while the prompt was up
        #expect(!lock.unlockSettings(pin: "1234", since: generation))
        #expect(!lock.canEditSettings)
        #expect(lock.unlockSettings(pin: "1234", since: lock.lockGeneration))
        #expect(lock.canEditSettings)
    }
}

@Suite(.serialized)
struct ScheduleLockTests {
    @Test func lockedScheduleChangesAreRefused() {
        var schedule = makeSchedule((9, 0), (9, 30))
        let h = Harness(schedules: [schedule])
        h.pinLock.enable(pin: "1234")

        h.manager.addSchedule(makeSchedule((10, 0), (10, 30)))
        schedule.name = "Changed"
        h.manager.updateSchedule(schedule)
        h.manager.deleteSchedule(schedule)
        #expect(h.manager.schedules.count == 1)
        #expect(h.manager.schedules.first?.name == "Break")

        h.pinLock.unlockSettings(pin: "1234", since: h.pinLock.lockGeneration)
        h.manager.updateSchedule(schedule)
        #expect(h.manager.schedules.first?.name == "Changed")
    }

    @Test func lockedSettingsChangesAreRefused() {
        let schedule = makeSchedule((9, 0), (9, 30))
        let h = Harness(schedules: [schedule])
        setClock(date(2026, 10, 19, 8, 0))
        h.manager.setNotificationLeadTime(10)
        h.pinLock.enable(pin: "1234")
        let pending = h.notifications.fireDate(for: schedule)

        #expect(!h.manager.setSnoozeDuration(15))
        #expect(!h.manager.setNotificationLeadTime(1))
        #expect(h.manager.snoozeDuration == 5)
        #expect(h.manager.notificationLeadTime == 10)
        #expect(h.defaults.object(forKey: "ScreenBlocker.snoozeDuration") as? Int == 5)
        #expect(h.defaults.object(forKey: "ScreenBlocker.notificationLeadTime") as? Int == 10)
        #expect(h.notifications.fireDate(for: schedule) == pending)

        h.pinLock.unlockSettings(pin: "1234", since: h.pinLock.lockGeneration)
        #expect(h.manager.setSnoozeDuration(15))
        #expect(h.manager.snoozeDuration == 15)
    }

    @Test func savedSettingsLoadWhileLocked() {
        let h = Harness()
        h.manager.setSnoozeDuration(1)
        h.manager.setNotificationLeadTime(15)
        h.pinLock.enable(pin: "1234")
        let reloaded = ScheduleManager(
            defaults: h.defaults, stats: h.stats, overlay: FakeOverlay(), notificationCenter: FakeNotificationCenter(),
            pinLock: PinLock(defaults: h.defaults)
        )
        #expect(reloaded.snoozeDuration == 1)
        #expect(reloaded.notificationLeadTime == 15)
    }

    @Test func blockStartingLocksSchedulesAgain() {
        let h = Harness(schedules: [makeSchedule((9, 0), (9, 30))])
        h.pinLock.enable(pin: "1234")
        h.pinLock.unlockSettings(pin: "1234", since: h.pinLock.lockGeneration)
        h.tick(at: date(2026, 10, 19, 8, 59))
        #expect(h.pinLock.canEditSettings)

        h.tick(at: date(2026, 10, 19, 9, 0))
        #expect(!h.pinLock.canEditSettings)
    }

    @Test func blockStartingRightAfterAnotherLocksSchedulesAgain() {
        let h = Harness(schedules: [makeSchedule((9, 0), (9, 30), name: "A"), makeSchedule((9, 30), (10, 0), name: "B")])
        h.pinLock.enable(pin: "1234")
        h.tick(at: date(2026, 10, 19, 9, 0))
        h.pinLock.unlockSettings(pin: "1234", since: h.pinLock.lockGeneration)

        h.tick(at: date(2026, 10, 19, 9, 30))
        #expect(h.manager.activeSchedule?.name == "B")
        #expect(!h.pinLock.canEditSettings)
    }

    @Test func replacingASnoozedBlockNeedsAuthorizationWithPin() {
        let a = makeSchedule((9, 0), (9, 30), name: "A")
        let b = makeSchedule((9, 10), (10, 0), name: "B")
        let h = Harness(schedules: [a, b])
        h.pinLock.enable(pin: "1234")
        h.tick(at: date(2026, 10, 19, 9, 0))
        setClock(date(2026, 10, 19, 9, 8))
        h.manager.snooze(minutes: 5)
        let snoozedBlockID = h.manager.currentBlockID

        setClock(date(2026, 10, 19, 9, 11))
        h.manager.startManualBlock(from: b)
        #expect(h.manager.isSnoozed)
        #expect(!h.manager.isBlocking)

        h.manager.startManualBlock(from: b, replacingSnoozedBlock: UUID())
        #expect(h.manager.isSnoozed)

        h.manager.startManualBlock(from: b, replacingSnoozedBlock: snoozedBlockID)
        #expect(h.manager.isBlocking)
        #expect(h.manager.activeSchedule?.name == "B")
    }

    @Test func replacingASnoozedBlockIsFreeWithoutPin() {
        let a = makeSchedule((9, 0), (9, 30), name: "A")
        let b = makeSchedule((9, 10), (10, 0), name: "B")
        let h = Harness(schedules: [a, b])
        h.tick(at: date(2026, 10, 19, 9, 0))
        setClock(date(2026, 10, 19, 9, 8))
        h.manager.snooze(minutes: 5)

        setClock(date(2026, 10, 19, 9, 11))
        h.manager.startManualBlock(from: b)
        #expect(h.manager.isBlocking)
        #expect(h.manager.activeSchedule?.name == "B")
    }

    @Test func resumeRightAfterSnoozeRunsOutCannotReplaceTheBlock() {
        let a = makeSchedule((9, 0), (9, 10), name: "A")
        let b = makeSchedule((9, 10), (9, 15), name: "B")
        let h = Harness(schedules: [a, b])
        h.pinLock.enable(pin: "1234")
        h.tick(at: date(2026, 10, 19, 9, 0))
        setClock(date(2026, 10, 19, 9, 1))
        h.manager.snooze(minutes: 10)  // Back at 9:11, now ending at 9:20
        let blockID = h.manager.currentBlockID

        // The snooze has run out but no tick has run yet
        setClock(date(2026, 10, 19, 9, 11))
        #expect(!h.manager.resumeReplacesSnoozedBlock(b))
        h.manager.startManualBlock(from: b)
        #expect(h.manager.isBlocking)
        #expect(!h.manager.isManualBlock)
        #expect(h.manager.currentBlockID == blockID)
        #expect(h.manager.currentBlockEndTime == date(2026, 10, 19, 9, 20))
        #expect(!h.manager.canSnooze)
    }

    @Test func resumingAnotherScheduleWhileOneIsSnoozedIsFlagged() {
        let a = makeSchedule((9, 0), (9, 30), name: "A")
        let b = makeSchedule((9, 10), (10, 0), name: "B")
        let h = Harness(schedules: [a, b])
        h.tick(at: date(2026, 10, 19, 9, 0))
        setClock(date(2026, 10, 19, 9, 8))
        h.manager.snooze(minutes: 5)

        setClock(date(2026, 10, 19, 9, 11))
        #expect(h.manager.canResume(b))
        #expect(h.manager.resumeReplacesSnoozedBlock(b))
        #expect(!h.manager.resumeReplacesSnoozedBlock(a))
    }

    @Test func cannotResumeWhileBlocking() {
        let schedule = makeSchedule((9, 0), (9, 30))
        let h = Harness(schedules: [schedule])
        h.tick(at: date(2026, 10, 19, 9, 0))
        #expect(!h.manager.canResume(schedule))

        // Including once a snooze has run out and the block is back
        setClock(date(2026, 10, 19, 9, 1))
        h.manager.snooze(minutes: 5)
        h.tick(at: date(2026, 10, 19, 9, 7))
        #expect(h.manager.isBlocking)
        #expect(!h.manager.canResume(schedule))
    }
}

@Suite(.serialized)
struct SnoozeAllowanceTests {
    @Test func eachBlockCanBeSnoozedOnce() {
        let h = Harness(schedules: [makeSchedule((9, 0), (9, 30))])
        h.tick(at: date(2026, 10, 19, 9, 0))
        #expect(h.manager.canSnooze)

        setClock(date(2026, 10, 19, 9, 2))
        #expect(h.manager.snooze(minutes: 5))
        h.tick(at: date(2026, 10, 19, 9, 7))
        #expect(h.manager.isBlocking)
        #expect(!h.manager.canSnooze)

        setClock(date(2026, 10, 19, 9, 8))
        #expect(!h.manager.snooze(minutes: 10))
        #expect(h.manager.isBlocking)

        // The next day's block gets its own snooze
        h.tick(at: date(2026, 10, 19, 9, 35))
        h.tick(at: date(2026, 10, 20, 9, 0))
        #expect(h.manager.canSnooze)
    }

    @Test func scheduleCanDisallowSnoozing() {
        var schedule = makeSchedule((9, 0), (9, 30))
        schedule.allowsSnooze = false
        let h = Harness(schedules: [schedule])
        h.tick(at: date(2026, 10, 19, 9, 0))
        #expect(!h.manager.canSnooze)
        #expect(!h.manager.snooze(minutes: 5))
        #expect(h.manager.isBlocking)
    }

    @Test func overlappingSchedulesMustAllAllowSnoozing() {
        var strict = makeSchedule((9, 10), (9, 20), name: "Strict")
        strict.allowsSnooze = false
        let owner = makeSchedule((9, 0), (10, 0), name: "Owner")
        let h = Harness(schedules: [owner, strict])

        h.tick(at: date(2026, 10, 19, 9, 0))
        #expect(h.manager.canSnooze)
        h.tick(at: date(2026, 10, 19, 9, 15))
        #expect(h.manager.activeSchedule?.name == "Owner")
        #expect(!h.manager.canSnooze)
        h.tick(at: date(2026, 10, 19, 9, 25))
        #expect(h.manager.canSnooze)
    }

    @Test func resumingTheSnoozedScheduleKeepsItsSnoozeUsed() {
        let schedule = makeSchedule((9, 0), (9, 30))
        let h = Harness(schedules: [schedule])
        h.tick(at: date(2026, 10, 19, 9, 0))
        setClock(date(2026, 10, 19, 9, 2))
        h.manager.snooze(minutes: 5)

        setClock(date(2026, 10, 19, 9, 3))
        h.manager.startManualBlock(from: schedule)
        #expect(h.manager.isBlocking)
        #expect(!h.manager.canSnooze)
    }

    @Test func sleepAndWakeKeepTheSnoozeUsed() {
        let h = Harness(schedules: [makeSchedule((9, 0), (9, 30))])
        h.tick(at: date(2026, 10, 19, 9, 0))
        setClock(date(2026, 10, 19, 9, 2))
        h.manager.snooze(minutes: 5)
        h.tick(at: date(2026, 10, 19, 9, 7))
        let blockID = h.manager.currentBlockID

        h.sleep(at: date(2026, 10, 19, 9, 10))
        h.wake(at: date(2026, 10, 19, 9, 20))
        #expect(h.manager.isBlocking)
        #expect(h.manager.currentBlockID == blockID)
        #expect(!h.manager.canSnooze)
    }

    @Test func turningSnoozeOffAndOnDoesNotRestoreIt() {
        var schedule = makeSchedule((9, 0), (9, 30))
        let h = Harness(schedules: [schedule])
        h.tick(at: date(2026, 10, 19, 9, 0))
        setClock(date(2026, 10, 19, 9, 2))
        h.manager.snooze(minutes: 5)
        h.tick(at: date(2026, 10, 19, 9, 7))

        schedule.allowsSnooze = false
        h.manager.updateSchedule(schedule)
        schedule.allowsSnooze = true
        h.manager.updateSchedule(schedule)
        #expect(!h.manager.canSnooze)
    }

    @Test func resumedBlockHandingOverToAnOverlapIsOneBlock() {
        let a = makeSchedule((9, 0), (9, 30), name: "A")
        let b = makeSchedule((9, 20), (10, 0), name: "B")
        let h = Harness(schedules: [a, b])
        h.tick(at: date(2026, 10, 19, 9, 0))
        setClock(date(2026, 10, 19, 9, 1))
        h.manager.snooze(minutes: 5)
        setClock(date(2026, 10, 19, 9, 2))
        h.manager.startManualBlock(from: a)
        let blockID = h.manager.currentBlockID

        // The resumed block runs to A's extended end, then B (already running) carries it on
        h.tick(at: date(2026, 10, 19, 9, 20))
        h.tick(at: date(2026, 10, 19, 9, 35))
        #expect(h.manager.isBlocking)
        #expect(!h.manager.isManualBlock)
        #expect(h.manager.activeSchedule?.name == "B")
        #expect(h.manager.currentBlockID == blockID)
        #expect(!h.manager.canSnooze)
        #expect(h.savedSessions().count == 1)
    }

    @Test func separateBlockGetsItsOwnSnooze() {
        let h = Harness(schedules: [makeSchedule((9, 0), (9, 30), name: "A"), makeSchedule((9, 40), (10, 0), name: "B")])
        h.tick(at: date(2026, 10, 19, 9, 0))
        setClock(date(2026, 10, 19, 9, 2))
        h.manager.snooze(minutes: 5)
        h.tick(at: date(2026, 10, 19, 9, 7))
        #expect(!h.manager.canSnooze)

        h.tick(at: date(2026, 10, 19, 9, 35))
        h.tick(at: date(2026, 10, 19, 9, 40))
        #expect(h.manager.activeSchedule?.name == "B")
        #expect(h.manager.canSnooze)
    }

    @Test func snoozeExtensionRunningIntoTheNextScheduleKeepsItOneBlock() {
        let h = Harness(schedules: [makeSchedule((9, 0), (9, 30), name: "A"), makeSchedule((9, 30), (10, 0), name: "B")])
        h.tick(at: date(2026, 10, 19, 9, 0))
        setClock(date(2026, 10, 19, 9, 2))
        h.manager.snooze(minutes: 5)  // A now ends at 9:35, overlapping B
        h.tick(at: date(2026, 10, 19, 9, 7))

        h.tick(at: date(2026, 10, 19, 9, 35))
        #expect(h.manager.activeSchedule?.name == "B")
        #expect(!h.manager.canSnooze)
    }

    @Test func requestsForAnEndedBlockAreRefused() {
        let h = Harness(schedules: [makeSchedule((9, 0), (9, 30), name: "A"), makeSchedule((9, 30), (10, 0), name: "B")])
        h.tick(at: date(2026, 10, 19, 9, 0))
        let first = h.manager.currentBlockID
        h.tick(at: date(2026, 10, 19, 9, 30))
        let second = h.manager.currentBlockID
        #expect(first != second)

        #expect(!h.manager.snooze(minutes: 10, blockID: first))
        h.manager.exitBlockEarly(blockID: first)
        #expect(h.manager.isBlocking)

        h.manager.exitBlockEarly(blockID: second)
        #expect(!h.manager.isBlocking)
    }

    @Test func snoozeChecksTheBlockAsItIsNow() {
        var strict = makeSchedule((9, 30), (10, 0), name: "Strict")
        strict.allowsSnooze = false
        let h = Harness(schedules: [makeSchedule((9, 0), (9, 30), name: "A"), strict])
        h.tick(at: date(2026, 10, 19, 9, 29))
        #expect(h.manager.canSnooze)

        // A has ended and Strict has started, but no tick has run yet
        setClock(date(2026, 10, 19, 9, 30))
        #expect(!h.manager.snooze(minutes: 10))
        #expect(h.manager.isBlocking)
        #expect(h.manager.activeSchedule?.name == "Strict")
    }

    @Test func snoozeLengthComesFromTheSetting() {
        let h = Harness(schedules: [makeSchedule((9, 0), (9, 30))])
        h.manager.setSnoozeDuration(15)
        h.tick(at: date(2026, 10, 19, 9, 0))
        setClock(date(2026, 10, 19, 9, 2))
        #expect(h.manager.snooze())
        #expect(h.manager.snoozeEndTime == date(2026, 10, 19, 9, 17))
        #expect(h.manager.currentBlockEndTime == date(2026, 10, 19, 9, 45))
    }

    @Test func snoozeLengthOffTurnsSnoozingOff() {
        let h = Harness(schedules: [makeSchedule((9, 0), (9, 30))])
        h.manager.setSnoozeDuration(0)
        h.tick(at: date(2026, 10, 19, 9, 0))
        #expect(!h.manager.canSnooze)
        #expect(!h.manager.snooze())
        #expect(h.manager.isBlocking)
    }

    @Test func snoozeLengthPersists() {
        let h = Harness()
        h.manager.setSnoozeDuration(10)
        let reloaded = ScheduleManager(
            defaults: h.defaults, stats: h.stats, overlay: FakeOverlay(), notificationCenter: FakeNotificationCenter(),
            pinLock: h.pinLock
        )
        #expect(reloaded.snoozeDuration == 10)
    }

    @Test func changingTheLengthDoesNotAffectARunningSnoozeOrRestoreTheAllowance() {
        let h = Harness(schedules: [makeSchedule((9, 0), (9, 30))])
        h.manager.setSnoozeDuration(15)
        h.tick(at: date(2026, 10, 19, 9, 0))
        let blockID = h.manager.currentBlockID
        setClock(date(2026, 10, 19, 9, 2))
        h.manager.snooze()

        h.manager.setSnoozeDuration(0)
        h.tick(at: date(2026, 10, 19, 9, 3))
        #expect(h.manager.snoozeEndTime == date(2026, 10, 19, 9, 17))
        #expect(h.manager.currentBlockEndTime == date(2026, 10, 19, 9, 45))

        h.tick(at: date(2026, 10, 19, 9, 17))
        #expect(h.manager.isBlocking)
        #expect(h.manager.currentBlockID == blockID)
        h.manager.setSnoozeDuration(5)
        #expect(!h.manager.canSnooze)
        #expect(!h.manager.snooze())
    }

    @Test func turningSnoozeBackOnMidBlockUsesTheNewLength() {
        let h = Harness(schedules: [makeSchedule((9, 0), (9, 30))])
        h.tick(at: date(2026, 10, 19, 9, 0))
        let blockID = h.manager.currentBlockID
        h.manager.setSnoozeDuration(0)
        #expect(!h.manager.snooze(minutes: 15))

        h.manager.setSnoozeDuration(1)
        #expect(h.manager.currentBlockID == blockID)
        #expect(h.manager.snooze())
        #expect(h.manager.snoozeEndTime == date(2026, 10, 19, 9, 1))
    }

    @Test func snoozeLengthDoesNotOverrideAStrictOverlap() {
        var strict = makeSchedule((9, 5), (9, 45))
        strict.allowsSnooze = false
        let h = Harness(schedules: [makeSchedule((9, 0), (9, 30)), strict])
        h.tick(at: date(2026, 10, 19, 9, 6))
        for minutes in [0, 1, 5, 10, 15] {
            h.manager.setSnoozeDuration(minutes)
            #expect(!h.manager.canSnooze)
            #expect(!h.manager.snooze())
        }
    }

    @Test func savedOffIsKeptRatherThanTheDefault() {
        let h = Harness()
        #expect(h.manager.snoozeDuration == 5)
        h.manager.setSnoozeDuration(0)
        let reloaded = ScheduleManager(
            defaults: h.defaults, stats: h.stats, overlay: FakeOverlay(), notificationCenter: FakeNotificationCenter(),
            pinLock: h.pinLock
        )
        #expect(reloaded.snoozeDuration == 0)
    }

    @Test func savedSchedulesWithoutTheSettingAllowSnoozing() throws {
        let data = try JSONEncoder().encode(makeSchedule((9, 0), (9, 30)))
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "allowsSnooze")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(Schedule.self, from: legacy).allowsSnooze)
    }
}
