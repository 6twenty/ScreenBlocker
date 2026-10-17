import AppKit
import UserNotifications

public class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController!
    private var scheduleManager: ScheduleManager!

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
    }

    /// Accessory apps don't show a menu bar, but key equivalents are still routed through the
    /// main menu. Without these items, Cmd-C/V/X/A/Z don't work in text fields and Cmd-W
    /// doesn't close the Settings window.
    private func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        // The first item is always treated as the application menu
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = NSMenu()
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

    public func applicationWillTerminate(_ notification: Notification) {
        // Close any open stats session so the time the app is gone isn't counted
        scheduleManager.handleAppTermination()

        // Clear pending notifications - they're only useful if the app is running
        // (a "block starting soon" notification is misleading if no block will actually start)
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }
}
