import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

struct GeneralTab: View {
    @ObservedObject private var manager = ScheduleManager.shared
    @ObservedObject private var pinLock = PinLock.shared
    @State private var notificationsDenied = false
    @State private var launchAtLogin = false
    @State private var loginItemNeedsApproval = false
    @State private var loginItemError: String?
    // Changed to rebuild the controls after a refused change, so they don't keep showing the rejected value
    @State private var formID = UUID()

    private var isLocked: Bool {
        !pinLock.canEditSettings
    }

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: setLaunchAtLogin
                ))
                .disabled(isLocked)

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

            Section("PIN") {
                Toggle("Require a PIN for changes", isOn: Binding(
                    get: { pinLock.isEnabled },
                    // Async, since turning it on shows a prompt
                    set: { enabled in DispatchQueue.main.async { setPinRequired(enabled) } }
                ))
                .disabled(isLocked)
                Text("Settings stay locked until unlocked with the PIN. Quitting, exiting a block early, and resuming a block in place of a snoozed one also need it.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }

            Section("Snooze") {
                Picker("Snooze length", selection: Binding(
                    get: { manager.snoozeDuration },
                    set: { minutes in refreshIfRefused(manager.setSnoozeDuration(minutes)) }
                )) {
                    ForEach(Self.durationChoices, id: \.minutes) { choice in
                        Text(choice.label).tag(choice.minutes)
                    }
                }
                .disabled(isLocked)
                Text("Each block can be snoozed once, for schedules that allow it. Changes apply from the next snooze. Off turns snoozing off for every schedule.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }

            Section("Notifications") {
                Picker("Notify before a block starts", selection: Binding(
                    get: { manager.notificationLeadTime },
                    set: { minutes in refreshIfRefused(manager.setNotificationLeadTime(minutes)) }
                )) {
                    ForEach(Self.durationChoices, id: \.minutes) { choice in
                        Text(choice.label).tag(choice.minutes)
                    }
                }
                .disabled(isLocked)

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
        .id(formID)
        .onChange(of: pinLock.isSettingsUnlocked) { unlocked in
            // Locked again (e.g. a block started): drop anything a still-open control was about to change
            if !unlocked {
                formID = UUID()
            }
        }
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

    /// Shared by the notification and snooze pickers
    private static let durationChoices: [(minutes: Int, label: String)] =
        [(0, "Off")] + [1, 5, 10, 15].map { ($0, ScheduleManager.describeMinutes($0)) }

    private func refreshIfRefused(_ accepted: Bool) {
        if !accepted {
            formID = UUID()
        }
    }

    private func setPinRequired(_ required: Bool) {
        guard required != pinLock.isEnabled else { return }
        if required {
            if let pin = PinPrompt.requestNewPin() {
                pinLock.enable(pin: pin)
            }
        } else {
            // Settings were unlocked with the PIN to get here
            refreshIfRefused(pinLock.disable())
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        guard pinLock.canEditSettings else {
            refreshLoginItemStatus()
            formID = UUID()
            return
        }
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
