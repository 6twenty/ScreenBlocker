import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

struct GeneralTab: View {
    @ObservedObject private var manager = ScheduleManager.shared
    @State private var notificationsDenied = false
    @State private var launchAtLogin = false
    @State private var loginItemNeedsApproval = false
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: setLaunchAtLogin
                ))

                if loginItemNeedsApproval {
                    Text("Approve ScreenBlocker in System Settings › General › Login Items.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                if let loginItemError {
                    Text(loginItemError)
                        .font(.callout)
                        .foregroundColor(.red)
                }
            }

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
        .onAppear(perform: refreshStatus)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Pick up changes made in System Settings while this window was in the background
            refreshStatus()
        }
    }

    private func refreshStatus() {
        refreshAuthorizationStatus()
        refreshLoginItemStatus()
    }

    private func refreshLoginItemStatus() {
        let status = SMAppService.mainApp.status
        // Registered but awaiting approval still counts as on, so the toggle reflects the choice
        launchAtLogin = status == .enabled || status == .requiresApproval
        loginItemNeedsApproval = status == .requiresApproval
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = "Couldn't update login item: \(error.localizedDescription)"
        }
        refreshLoginItemStatus()
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
