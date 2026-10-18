import AppKit
import UserNotifications

public class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController!
    private var scheduleManager: ScheduleManager!
    private var isSystemQuitting = false
    // Quit events held until we know whether the quit goes ahead, so a declined one can report "cancelled"
    private var pendingQuitEvents: [NSAppleEventManager.SuspensionID] = []

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Request notification permissions
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                print("Notification permission error: \(error)")
            }
        }

        // Initialize the schedule manager
        scheduleManager = ScheduleManager.shared

        // Initialize the status bar
        statusBarController = StatusBarController()

        // Ensure app doesn't appear in dock (backup in case Info.plist doesn't work)
        NSApp.setActivationPolicy(.accessory)

        NSApp.mainMenu = makeMainMenu()

        // AppKit refuses quit events while a modal alert is up, before asking the delegate. Handling them here
        // means a logout, restart or shutdown can close an open PIN prompt rather than being cancelled by it.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleQuitEvent(_:withReply:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEQuitApplication)
        )
    }

    @objc private func handleQuitEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        if Self.isSystemQuit(event) {
            // Also lets a quit check that's already waiting on a prompt go ahead
            isSystemQuitting = true
            PinPrompt.cancelOpenPrompt()
        }

        let eventManager = NSAppleEventManager.shared()
        guard let suspension = eventManager.suspendCurrentAppleEvent() else {
            NSApp.terminate(nil)
            return
        }
        pendingQuitEvents.append(suspension)

        // After any open prompt has unwound
        DispatchQueue.main.async { [weak self] in
            NSApp.terminate(nil)
            // Still running, so the quit was declined
            self?.pendingQuitEvents.removeAll { $0 == suspension }
            eventManager.replyAppleEvent(forSuspensionID: suspension)
                .setParam(NSAppleEventDescriptor(int32: Int32(userCanceledErr)), forKeyword: AEKeyword(keyErrorNumber))
            eventManager.resume(withSuspensionID: suspension)
        }
    }

    /// Accessory apps don't show a menu bar, but key equivalents are still routed through the
    /// main menu. Without these items, Cmd-C/V/X/A/Z don't work in text fields, Cmd-W
    /// doesn't close the Settings window, and Cmd-Q does nothing.
    private func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        // The first item is always treated as the application menu
        let appMenu = NSMenu()
        let quitItem = appMenu.addItem(withTitle: "Quit ScreenBlocker", action: #selector(StatusBarController.quit), keyEquivalent: "q")
        quitItem.target = statusBarController
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let windowMenuItem = NSMenuItem()
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        return mainMenu
    }

    /// Every quit route (menu, Cmd-Q, AppleScript) comes through here
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Logging out, restarting or shutting down always goes ahead
        if isSystemQuitting {
            return .terminateNow
        }
        // A system quit can arrive while the prompt is open, closing it
        return confirmQuit() || isSystemQuitting ? .terminateNow : .terminateCancel
    }

    private static func isSystemQuit(_ event: NSAppleEventDescriptor) -> Bool {
        guard event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEQuitApplication),
              let reason = event.paramDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue else {
            return false
        }
        let systemReasons = [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAERestart, kAEShowShutdownDialog, kAEShutDown]
        return systemReasons.map { OSType($0) }.contains(reason)
    }

    /// The PIN when that's on, otherwise a confirmation if a block is running or snoozed
    private func confirmQuit() -> Bool {
        let endsBlock = scheduleManager.isBlocking || scheduleManager.isSnoozed
        let consequence = "This ends the current block. It will be recorded as cancelled in your stats."

        if PinLock.shared.isEnabled {
            return PinPrompt.requestPin(
                title: "Quit ScreenBlocker?",
                message: endsBlock ? "Enter your PIN to quit. \(consequence)" : "Enter your PIN to quit."
            ) != nil
        }

        guard endsBlock else { return true }
        return PinPrompt.confirm(title: "Quit ScreenBlocker?", message: consequence, confirmTitle: "Quit")
    }

    public func applicationWillTerminate(_ notification: Notification) {
        // Quitting, so any held quit events succeeded
        let eventManager = NSAppleEventManager.shared()
        for suspension in pendingQuitEvents {
            eventManager.resume(withSuspensionID: suspension)
        }
        pendingQuitEvents.removeAll()

        // Close any open stats session so the time the app is gone isn't counted
        scheduleManager.handleAppTermination()

        // Clear pending notifications - they're only useful if the app is running
        // (a "block starting soon" notification is misleading if no block will actually start)
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }
}
