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
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @State private var selectedTab = 0

    var body: some View {
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
        }
        .frame(minWidth: 650, minHeight: 450)
    }
}
