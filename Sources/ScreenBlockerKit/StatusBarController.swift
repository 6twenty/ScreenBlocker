import AppKit
import Combine

class StatusBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem
    private var settingsWindowController: SettingsWindowController?
    private var updateTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var nextBlockMenuItem: NSMenuItem?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        super.init()

        if statusItem.button != nil {
            updateButtonTitle()
        }

        setupMenu()
        startUpdating()

        // Observe schedule changes
        ScheduleManager.shared.$nextBlockStartTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateButtonTitle()
            }
            .store(in: &cancellables)

        ScheduleManager.shared.$isBlocking
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateButtonTitle()
            }
            .store(in: &cancellables)

        ScheduleManager.shared.$snoozeEndTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateButtonTitle()
            }
            .store(in: &cancellables)
    }

    private func setupMenu() {
        let menu = NSMenu()
        menu.delegate = self

        // Next block info (updated dynamically)
        nextBlockMenuItem = NSMenuItem(title: "No upcoming blocks", action: nil, keyEquivalent: "")
        nextBlockMenuItem?.isEnabled = false
        menu.addItem(nextBlockMenuItem!)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit ScreenBlocker", action: #selector(quit), keyEquivalent: "q"))

        // Set targets
        for item in menu.items {
            item.target = self
        }

        statusItem.menu = menu
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        updateNextBlockMenuItem()
    }

    private func updateNextBlockMenuItem() {
        let manager = ScheduleManager.shared
        let formatter = DateFormatter()
        formatter.timeStyle = .short

        if manager.isBlocking, let schedule = manager.activeSchedule {
            nextBlockMenuItem?.title = "Currently blocking: \(schedule.name)"
        } else if manager.isSnoozed, let snoozeEnd = manager.snoozeEndTime, let schedule = manager.activeSchedule {
            nextBlockMenuItem?.title = "Snoozed: \(schedule.name) resumes at \(formatter.string(from: snoozeEnd))"
        } else if let nextTime = manager.nextBlockStartTime {
            let nextScheduleName = manager.nextSchedule?.name ?? "Block"
            nextBlockMenuItem?.title = "Next: \(nextScheduleName) at \(formatter.string(from: nextTime))"
        } else {
            nextBlockMenuItem?.title = "No upcoming blocks"
        }
    }

    private func startUpdating() {
        // Update the menu bar title every 30 seconds
        updateTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.updateButtonTitle()
        }
    }

    private func updateButtonTitle() {
        guard let button = statusItem.button else { return }

        let manager = ScheduleManager.shared

        if manager.isBlocking {
            // Blocking state: pause icon
            if let image = NSImage(systemSymbolName: "pause.circle.fill", accessibilityDescription: "Blocking") {
                image.isTemplate = true
                button.image = image
            }
            button.title = " Blocking"
        } else if manager.isSnoozed, let timeUntil = manager.timeUntilNextBlock {
            // Snoozed state: show time until block resumes
            if let image = NSImage(systemSymbolName: "moon.zzz", accessibilityDescription: "Snoozed") {
                image.isTemplate = true
                button.image = image
            }
            button.title = " \(timeUntil)"
        } else if let timeUntil = manager.timeUntilNextBlock {
            // Normal state with countdown: clock icon
            if let image = NSImage(systemSymbolName: "clock", accessibilityDescription: "Time until next block") {
                image.isTemplate = true
                button.image = image
            }
            button.title = " \(timeUntil)"
        } else {
            // No schedules: clock icon
            if let image = NSImage(systemSymbolName: "clock", accessibilityDescription: "ScreenBlocker") {
                image.isTemplate = true
                button.image = image
            }
            button.title = ""
        }

        button.imagePosition = .imageLeading
    }

    @objc private func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
