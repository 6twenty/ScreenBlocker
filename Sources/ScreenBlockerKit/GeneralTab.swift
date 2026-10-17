import AppKit
import SwiftUI
import UserNotifications

struct GeneralTab: View {
    @ObservedObject private var manager = ScheduleManager.shared
    @State private var notificationsDenied = false

    var body: some View {
        Form {
            Section("Notifications") {
                Picker("Notify before a block starts", selection: $manager.notificationLeadTime) {
                    Text("Off").tag(0)
                    Text("1 minute").tag(1)
                    Text("5 minutes").tag(5)
                    Text("10 minutes").tag(10)
                    Text("15 minutes").tag(15)
                }
                .onChange(of: manager.notificationLeadTime) { _ in
                    manager.saveSettings()
                }

                if notificationsDenied && manager.notificationLeadTime > 0 {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.yellow)
                        Text("Notifications for ScreenBlocker are turned off in System Settings.")
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Open System Settings…", action: openNotificationSettings)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshAuthorizationStatus)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Pick up changes made in System Settings while this window was in the background
            refreshAuthorizationStatus()
        }
    }

    private func refreshAuthorizationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                notificationsDenied = settings.authorizationStatus == .denied
            }
        }
    }

    private func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
