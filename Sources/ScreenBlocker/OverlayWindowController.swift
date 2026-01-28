import AppKit
import SwiftUI

class OverlayWindowController {
    static let shared = OverlayWindowController()

    private var overlayWindows: [NSWindow] = []

    private init() {}

    func showOverlay() {
        // Create an overlay window for each screen
        for screen in NSScreen.screens {
            let window = createOverlayWindow(for: screen)
            overlayWindows.append(window)
            window.orderFrontRegardless()
        }
    }

    func hideOverlay() {
        for window in overlayWindows {
            window.close()
        }
        overlayWindows.removeAll()
    }

    private func createOverlayWindow(for screen: NSScreen) -> NSWindow {
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.level = .screenSaver // High level, above most windows
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true

        // Set the SwiftUI overlay view
        let overlayView = OverlayView()
        window.contentView = NSHostingView(rootView: overlayView)

        return window
    }
}

struct OverlayView: View {
    @ObservedObject private var manager = ScheduleManager.shared

    var body: some View {
        ZStack {
            // Semi-transparent dark background
            Color.black.opacity(0.85)
                .ignoresSafeArea()

            VStack(spacing: 40) {
                Text("Time for a Break")
                    .font(.system(size: 64, weight: .bold))
                    .foregroundColor(.white)

                if let endTime = manager.currentBlockEndTime {
                    Text("Until \(endTime, formatter: timeFormatter)")
                        .font(.system(size: 32))
                        .foregroundColor(.white.opacity(0.8))

                    Text(timeRemaining(until: endTime))
                        .font(.system(size: 48, weight: .medium, design: .monospaced))
                        .foregroundColor(.white)
                }

                Spacer().frame(height: 40)

                Button(action: {
                    manager.snooze(minutes: 5)
                }) {
                    Text("5 More Minutes")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 40)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.blue)
                        )
                }
                .buttonStyle(.plain)

                Text("(adds 5 minutes to this block)")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
    }

    private var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }

    private func timeRemaining(until endTime: Date) -> String {
        let interval = endTime.timeIntervalSince(Date())
        guard interval > 0 else { return "0:00" }

        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
