import AppKit
import SwiftUI

class SettingsWindowController: NSWindowController {
    convenience init() {
        let settingsView = SettingsView()
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "ScreenBlocker Settings"
        window.contentViewController = hostingController
        window.center()
        window.setFrameAutosaveName("SettingsWindow")

        self.init(window: window)

        // Unlocked settings lock again when the window closes (it's kept and reused, so not on disappear)
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            PinLock.shared.lockSettings()
        }
    }

    private var closeObserver: NSObjectProtocol?

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject private var pinLock = PinLock.shared
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            if pinLock.isEnabled {
                SettingsLockBar()
                Divider()
            }
            tabs
        }
        .frame(minWidth: 650, minHeight: 450)
    }

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            SchedulesTab()
                .tabItem {
                    Label("Schedules", systemImage: "calendar")
                }
                .tag(0)

            StatsTab()
                .tabItem {
                    Label("Stats", systemImage: "chart.bar")
                }
                .tag(1)

            GeneralTab()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag(2)
        }
    }
}

/// Shown while the PIN is on: one unlock covers every tab
struct SettingsLockBar: View {
    @ObservedObject private var pinLock = PinLock.shared

    var body: some View {
        HStack {
            if pinLock.isSettingsUnlocked {
                Label("Unlocked. Changes save as you make them.", systemImage: "lock.open")
                Spacer()
                Button("Lock") {
                    pinLock.lockSettings()
                }
            } else {
                Label("Settings are locked.", systemImage: "lock")
                Spacer()
                Button("Unlock…", action: unlock)
            }
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func unlock() {
        let generation = pinLock.lockGeneration
        let pin = PinPrompt.requestPin(
            title: "Unlock Settings",
            message: "Enter your PIN to make changes.",
            cancelIf: { pinLock.lockGeneration != generation }
        )
        if let pin {
            pinLock.unlockSettings(pin: pin, since: generation)
        }
    }
}
