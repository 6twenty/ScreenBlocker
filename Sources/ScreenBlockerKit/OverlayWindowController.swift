import AppKit
import SwiftUI
import Combine

class OverlayWindowController: ObservableObject {
    static let shared = OverlayWindowController()

    private var overlayWindows: [NSWindow] = []
    private var isShowingOverlay = false
    private let fadeDuration: TimeInterval = 1.0
    private let contentDelay: TimeInterval = 0.5

    // State-driven content visibility (fallback for missed notifications)
    @Published var shouldShowContent: Bool = false

    // Notifications for coordinating content fade (still used for animation timing)
    static let contentFadeInNotification = Notification.Name("OverlayContentFadeIn")
    static let contentFadeOutNotification = Notification.Name("OverlayContentFadeOut")

    private init() {
        // Observe screen configuration changes (monitor connect/disconnect)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        // If overlay is showing, refresh to cover new screen configuration
        // Ensure we're on main thread for AppKit operations
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isShowingOverlay else { return }
            self.refreshOverlay()
        }
    }

    func showOverlay() {
        // Clear any existing windows first (but keep isShowingOverlay true for refresh)
        for window in overlayWindows {
            window.orderOut(nil)
        }
        overlayWindows.removeAll()

        isShowingOverlay = true

        // Create an overlay window for each screen
        for screen in NSScreen.screens {
            let window = createOverlayWindow(for: screen)
            window.alphaValue = 0  // Start transparent
            overlayWindows.append(window)
            window.orderFrontRegardless()
        }

        // Fade in background
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for window in overlayWindows {
                window.animator().alphaValue = 1
            }
        }

        // After delay, fade in content
        DispatchQueue.main.asyncAfter(deadline: .now() + contentDelay) { [weak self] in
            // Guard against stale closure: if hideOverlay() was called before this fires,
            // don't flip state back to true
            guard let self = self, self.isShowingOverlay else { return }
            self.shouldShowContent = true
            NotificationCenter.default.post(name: Self.contentFadeInNotification, object: nil)
        }
    }

    func hideOverlay() {
        isShowingOverlay = false
        shouldShowContent = false
        let windowsToHide = overlayWindows
        overlayWindows.removeAll()

        // First, fade out content
        NotificationCenter.default.post(name: Self.contentFadeOutNotification, object: nil)

        // After content starts fading, fade out background
        DispatchQueue.main.asyncAfter(deadline: .now() + contentDelay) {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = self.fadeDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                for window in windowsToHide {
                    window.animator().alphaValue = 0
                }
            }, completionHandler: {
                for window in windowsToHide {
                    window.orderOut(nil)
                }
            })
        }
    }

    /// Ensure overlay is visible if it should be (defensive check for post-wake scenarios)
    func ensureOverlayVisible() {
        guard isShowingOverlay else { return }

        // If we have no windows but should be showing, refresh
        if overlayWindows.isEmpty {
            refreshOverlay()
        }
    }

    /// Refresh overlay without animation (for screen configuration changes)
    private func refreshOverlay() {
        for window in overlayWindows {
            window.orderOut(nil)
        }
        overlayWindows.removeAll()

        for screen in NSScreen.screens {
            let window = createOverlayWindow(for: screen)
            window.alphaValue = 1  // Already visible, no fade needed
            overlayWindows.append(window)
            window.orderFrontRegardless()
        }
        // Content should already be visible for refresh - set state before posting notification
        shouldShowContent = true
        NotificationCenter.default.post(name: Self.contentFadeInNotification, object: nil)
    }

    private func createOverlayWindow(for screen: NSScreen) -> NSWindow {
        // Use full screen frame - menu bar remains visible since it's at a higher window level
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.level = .floating // Above normal windows, but below system dialogs (Force Quit, etc.)
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
    @ObservedObject private var overlayController = OverlayWindowController.shared
    @State private var currentTime = Date()
    @State private var showExitConfirmation = false
    @State private var contentOpacity: Double = 0

    // Cached display values (preserved during fade out)
    @State private var displayName: String = "Time for a Break"
    @State private var displayMessage: String = ""
    @State private var displayEndTime: Date?

    // Timer that fires every second to update the countdown
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // Content fade notifications
    private let fadeInPublisher = NotificationCenter.default.publisher(for: OverlayWindowController.contentFadeInNotification)
    private let fadeOutPublisher = NotificationCenter.default.publisher(for: OverlayWindowController.contentFadeOutNotification)

    var body: some View {
        ZStack {
            // Frosted glass effect with dark tint (Apple-like material)
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            // Dark overlay for better text contrast
            Color.black.opacity(0.5)
                .ignoresSafeArea()

            // Content with separate opacity
            VStack(spacing: 30) {
                // Schedule name as title
                Text(displayName)
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                // Custom message if present
                if !displayMessage.isEmpty {
                    Text(displayMessage)
                        .font(.title)
                        .foregroundColor(.white.opacity(0.9))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }

                Spacer().frame(height: 20)

                if let endTime = displayEndTime {
                    Text("Until \(endTime, formatter: Self.timeFormatter)")
                        .font(.title2)
                        .foregroundColor(.white.opacity(0.7))

                    Text(timeRemaining(until: endTime))
                        .font(.system(size: 48, weight: .medium, design: .monospaced))
                        .foregroundColor(.white)
                }

                Spacer().frame(height: 40)

                if canSnooze {
                    Button(action: {
                        manager.snooze(minutes: 5)
                    }) {
                        Text("5 More Minutes")
                            .font(.title3.weight(.semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(Color.white.opacity(0.2))
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)

                    Text("(adds 5 minutes to this block)")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            .opacity(contentOpacity)

            // Subtle exit button in bottom-right corner
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    ExitBlockButton {
                        showExitConfirmation = true
                    }
                    .padding(20)
                }
            }
            .opacity(contentOpacity)
        }
        .ignoresSafeArea()
        .onReceive(timer) { time in
            currentTime = time
            // Update end time display while content is visible
            if contentOpacity > 0, let endTime = manager.currentBlockEndTime {
                displayEndTime = endTime
            }
        }
        .onReceive(fadeInPublisher) { _ in
            // Capture current values before fading in
            displayName = manager.activeSchedule?.name ?? "Time for a Break"
            displayMessage = manager.activeSchedule?.message ?? ""
            displayEndTime = manager.currentBlockEndTime
            withAnimation(.easeInOut(duration: 1.0)) {
                contentOpacity = 1
            }
        }
        .onReceive(fadeOutPublisher) { _ in
            // Keep cached values during fade out
            withAnimation(.easeInOut(duration: 1.0)) {
                contentOpacity = 0
            }
        }
        .onAppear {
            // Fallback: if content should be visible but opacity is 0, fade in immediately.
            // This handles the race condition where the fade-in notification was posted
            // before this view subscribed (common after system wake).
            if overlayController.shouldShowContent && contentOpacity == 0 {
                displayName = manager.activeSchedule?.name ?? "Time for a Break"
                displayMessage = manager.activeSchedule?.message ?? ""
                displayEndTime = manager.currentBlockEndTime
                withAnimation(.easeInOut(duration: 1.0)) {
                    contentOpacity = 1
                }
            }
        }
        .onChange(of: overlayController.shouldShowContent) { shouldShow in
            // State-driven fallback: if state changes and we missed the notification
            if shouldShow && contentOpacity == 0 {
                displayName = manager.activeSchedule?.name ?? "Time for a Break"
                displayMessage = manager.activeSchedule?.message ?? ""
                displayEndTime = manager.currentBlockEndTime
                withAnimation(.easeInOut(duration: 1.0)) {
                    contentOpacity = 1
                }
            } else if !shouldShow && contentOpacity > 0 {
                withAnimation(.easeInOut(duration: 1.0)) {
                    contentOpacity = 0
                }
            }
        }
        .alert("Exit Block Early?", isPresented: $showExitConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Postpone 10 Minutes") {
                manager.snooze(minutes: 10)
            }
            Button("Exit Block", role: .destructive) {
                if manager.isManualBlock {
                    manager.stopManualBlock()
                } else {
                    manager.exitBlockEarly()
                }
            }
        } message: {
            Text("You can postpone for 10 minutes, or exit completely (which will be recorded in your stats).")
        }
    }

    /// Snooze button is only available within 5 minutes of the scheduled start time
    private var canSnooze: Bool {
        guard let schedule = manager.activeSchedule else { return false }

        // Compute today's scheduled start time
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: currentTime)
        components.hour = schedule.startHour
        components.minute = schedule.startMinute
        components.second = 0

        guard let scheduledStart = calendar.date(from: components) else { return false }

        // Handle overnight schedules - if current time is before start, scheduled start was yesterday
        var adjustedStart = scheduledStart
        if currentTime < scheduledStart {
            adjustedStart = calendar.date(byAdding: .day, value: -1, to: scheduledStart) ?? scheduledStart
        }

        let elapsed = currentTime.timeIntervalSince(adjustedStart)
        return elapsed >= 0 && elapsed < 5 * 60  // Within 5 minutes after scheduled start
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    private func timeRemaining(until endTime: Date) -> String {
        let interval = endTime.timeIntervalSince(currentTime)
        guard interval > 0 else { return "0:00" }

        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        let seconds = Int(interval) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
}

struct ExitBlockButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle")
                .font(.system(size: 18))
                .foregroundColor(.white.opacity(isHovered ? 0.6 : 0.25))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .help("Exit Block")
        .accessibilityLabel("Exit block early")
    }
}
