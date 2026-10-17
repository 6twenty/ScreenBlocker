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
    }

    public func applicationWillTerminate(_ notification: Notification) {
        // Close any open stats session so the time the app is gone isn't counted
        scheduleManager.handleAppTermination()

        // Clear pending notifications - they're only useful if the app is running
        // (a "block starting soon" notification is misleading if no block will actually start)
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }
}
