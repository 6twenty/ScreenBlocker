import AppKit
import SwiftUI
import Combine

/// What ScheduleManager needs from the overlay. Abstracted so tests don't create windows.
protocol OverlayPresenting: AnyObject {
    func showOverlay()
    func hideOverlay()
    func ensureOverlayVisible()
}

class OverlayWindowController: ObservableObject, OverlayPresenting {
    static let shared = OverlayWindowController()

    private var overlayWindows: [NSWindow] = []
    private var isShowingOverlay = false
    private var previousApp: NSRunningApplication?  // Had focus before the overlay took it
    private let fadeDuration: TimeInterval = 1.0
    private let contentDelay: TimeInterval = 0.5

    // State-driven content visibility (fallback for missed notifications)
    @Published var shouldShowContent: Bool = false

    // Notifications for coordinating content fade (still used for animation timing)
    static let contentFadeInNotification = Notification.Name("OverlayContentFadeIn")
    static let contentFadeOutNotification = Notification.Name("OverlayContentFadeOut")
    static let exitRequestedNotification = Notification.Name("OverlayExitRequested")

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
        previousApp = NSApp.isActive ? nil : NSWorkspace.shared.frontmostApplication

        // Create an overlay window for each screen
        for (index, screen) in NSScreen.screens.enumerated() {
            let window = createOverlayWindow(for: screen, isPrimary: index == 0)
            window.alphaValue = 0  // Start transparent
            overlayWindows.append(window)
            window.orderFrontRegardless()
        }
        takeKeyboardFocus()

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
        restoreKeyboardFocus()

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

        if !NSApp.isActive {
            previousApp = NSWorkspace.shared.frontmostApplication
        }
        for (index, screen) in NSScreen.screens.enumerated() {
            let window = createOverlayWindow(for: screen, isPrimary: index == 0)
            window.alphaValue = 1  // Already visible, no fade needed
            overlayWindows.append(window)
            window.orderFrontRegardless()
        }
        takeKeyboardFocus()
        // Content should already be visible for refresh - set state before posting notification
        shouldShowContent = true
        NotificationCenter.default.post(name: Self.contentFadeInNotification, object: nil)
    }

    /// Make the primary overlay window key, so keystrokes go to the overlay rather than the app hidden behind it
    private func takeKeyboardFocus() {
        NSApp.activate(ignoringOtherApps: true)
        // Disable Cmd-Tab while the overlay is up (macOS requires the Dock to be hidden for this).
        // Force Quit stays available. These options only apply while ScreenBlocker is active.
        NSApp.presentationOptions = [.hideDock, .disableProcessSwitching]
        // Process switching wasn't blocked while running as a menu-bar-only (accessory) app,
        // so act as a regular app while the overlay is up. The Dock is hidden, so no icon shows.
        NSApp.setActivationPolicy(.regular)
        overlayWindows.first?.makeKey()
    }

    /// Hand focus back to the app that had it before the overlay appeared
    private func restoreKeyboardFocus() {
        // Back to menu-bar-only before the Dock returns, so no Dock icon flashes up
        NSApp.setActivationPolicy(.accessory)
        NSApp.presentationOptions = []
        guard let app = previousApp else { return }
        previousApp = nil
        // Only if we still have focus (the user may have switched apps already)
        if NSApp.isActive && !app.isTerminated {
            app.activate(options: [])
        }
    }

    private func createOverlayWindow(for screen: NSScreen, isPrimary: Bool) -> NSWindow {
        // Use full screen frame - menu bar remains visible since it's at a higher window level
        let window = OverlayWindow(
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
        let overlayView = OverlayView(isPrimary: isPrimary)
        window.contentView = NSHostingView(rootView: overlayView)

        return window
    }
}

/// Borderless windows can't become key by default; the overlay needs to so it receives keystrokes.
private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Esc asks to exit
            NotificationCenter.default.post(name: OverlayWindowController.exitRequestedNotification, object: nil)
        case 48: // Tab keeps keyboard navigation between the overlay's buttons working
            super.keyDown(with: event)
        default:
            // Swallow other keys silently (no beep, and nothing reaches hidden apps)
            break
        }
    }
}

struct OverlayView: View {
    /// The overlay on the main display, which handles keyboard requests (so only one dialog appears)
    let isPrimary: Bool

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
    private let exitRequestedPublisher = NotificationCenter.default.publisher(for: OverlayWindowController.exitRequestedNotification)

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
                        Text("Snooze 5 Minutes")
                            .font(.title3.weight(.semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(Color.white.opacity(0.2))
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)

                    Text("The block will end 5 minutes later")
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
            fadeInContent()
        }
        .onReceive(exitRequestedPublisher) { _ in
            if isPrimary && contentOpacity > 0 {
                showExitConfirmation = true
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
                fadeInContent()
            }
        }
        .onChange(of: overlayController.shouldShowContent) { shouldShow in
            // State-driven fallback: if state changes and we missed the notification
            if shouldShow && contentOpacity == 0 {
                fadeInContent()
            } else if !shouldShow && contentOpacity > 0 {
                withAnimation(.easeInOut(duration: 1.0)) {
                    contentOpacity = 0
                }
            }
        }
        .alert("Exit Block Early?", isPresented: $showExitConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Snooze 10 Minutes") {
                manager.snooze(minutes: 10)
            }
            Button("Exit Block", role: .destructive) {
                manager.exitBlockEarly()
            }
        } message: {
            Text("Snoozing pauses the block for 10 minutes and moves its end time back to match. Exiting ends it now and is recorded in your stats.")
        }
    }

    /// Capture the current block's details, then fade the content in
    private func fadeInContent() {
        if let schedule = manager.activeSchedule,
           !schedule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            displayName = schedule.name
        } else {
            displayName = "Time for a Break"
        }
        displayMessage = manager.activeSchedule?.message ?? ""
        displayEndTime = manager.currentBlockEndTime
        withAnimation(.easeInOut(duration: 1.0)) {
            contentOpacity = 1
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
                .foregroundColor(.white.opacity(isHovered ? 0.7 : 0.4))
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
