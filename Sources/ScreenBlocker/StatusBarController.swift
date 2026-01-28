import AppKit
import Combine

class StatusBarController {
    private var statusItem: NSStatusItem
    private var settingsWindowController: SettingsWindowController?
    private var updateTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

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
    }

    private func setupMenu() {
        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit ScreenBlocker", action: #selector(quit), keyEquivalent: "q"))

        // Set targets
        for item in menu.items {
            item.target = self
        }

        statusItem.menu = menu
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
            button.title = "🛑 Blocking"
        } else if let timeUntil = manager.timeUntilNextBlock {
            button.title = "⏱ \(timeUntil)"
        } else {
            button.title = "⏱ --"
        }
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
