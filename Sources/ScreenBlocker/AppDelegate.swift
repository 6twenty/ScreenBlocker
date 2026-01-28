import AppKit
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController!
    private var scheduleManager: ScheduleManager!

    func applicationDidFinishLaunching(_ notification: Notification) {
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
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Cleanup if needed
    }
}
