import SwiftUI

struct StatsTab: View {
    @State private var selectedPeriod: StatsPeriod = .day
    @State private var offset: Int = 0
    @State private var sessions: [BlockSession] = []
    @State private var totals: BlockTotals = BlockTotals()

    // Keeps figures current while the tab is open (new sessions, running sessions, day rollover)
    private let refreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    // Cached formatters (DateFormatter is expensive to create)
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()

    var body: some View {
        VStack(spacing: 20) {
            // Period selector
            Picker("Period", selection: $selectedPeriod) {
                ForEach(StatsPeriod.allCases, id: \.self) { period in
                    Text(period.rawValue).tag(period)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 280)
            .onChange(of: selectedPeriod) { _ in
                offset = 0
                loadStats()
            }

            // Navigation
            VStack(spacing: 8) {
                HStack {
                    Button(action: { offset -= 1; loadStats() }) {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    .help("Previous")
                    .accessibilityLabel("Previous \(selectedPeriod.rawValue)")

                    Text(selectedPeriod.formatLabel(for: Date(), offset: offset))
                        .font(.headline)
                        .frame(minWidth: 150)

                    Button(action: { offset += 1; loadStats() }) {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.borderless)
                    .disabled(offset >= 0)
                    .help("Next")
                    .accessibilityLabel("Next \(selectedPeriod.rawValue)")
                }

                if offset != 0 {
                    Button(resetButtonLabel) {
                        offset = 0
                        loadStats()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundColor(.accentColor)
                }
            }

            // Totals display
            VStack(spacing: 12) {
                // Main total - active blocking time
                VStack(spacing: 4) {
                    Text("Total Block Time")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Text(formatDuration(totals.active))
                        .font(.system(size: 48, weight: .medium, design: .rounded))
                }

                // Secondary metrics
                if totals.snoozed > 0 || totals.sleeping > 0 {
                    HStack(spacing: 24) {
                        if totals.snoozed > 0 {
                            VStack(spacing: 2) {
                                Text("Snoozed")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(formatDuration(totals.snoozed))
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundColor(.orange)
                            }
                        }

                        if totals.sleeping > 0 {
                            VStack(spacing: 2) {
                                Text("Sleeping")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(formatDuration(totals.sleeping))
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 20)

            Divider()

            // Sessions list
            if sessions.isEmpty {
                Text("No blocks recorded for this period")
                    .foregroundColor(.secondary)
                    .frame(maxHeight: .infinity)
            } else {
                List(sessions) { session in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.scheduleName)
                                .fontWeight(.medium)
                            Text(formatSessionTime(session))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        HStack(spacing: 8) {
                            Text(formatDuration(sessionActiveTime(session)))
                                .font(.system(.body, design: .monospaced))

                            if let reason = session.endReason {
                                reasonBadge(for: reason)
                            } else {
                                stateBadge(for: session.currentState)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding()
        .onAppear {
            loadStats()
        }
        .onReceive(refreshTimer) { _ in
            loadStats()
        }
    }

    private var resetButtonLabel: String {
        switch selectedPeriod {
        case .day: return "Back to Today"
        case .week: return "Back to This Week"
        case .month: return "Back to This Month"
        case .year: return "Back to This Year"
        }
    }

    private func loadStats() {
        sessions = StatsManager.shared.sessions(for: selectedPeriod, offset: offset)
            .sorted { $0.createdAt > $1.createdAt }
        totals = StatsManager.shared.totals(for: sessions, period: selectedPeriod, offset: offset)
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60

        if hours > 0 {
            return String(format: "%dh %dm", hours, minutes)
        } else {
            return String(format: "%dm", minutes)
        }
    }

    private func formatSessionTime(_ session: BlockSession) -> String {
        let startStr = Self.timeFormatter.string(from: session.createdAt)
        let endStr: String
        if session.isOpen {
            endStr = "now"
        } else {
            endStr = Self.timeFormatter.string(from: session.events.last?.timestamp ?? session.createdAt)
        }

        if selectedPeriod != .day {
            let dateStr = Self.dateFormatter.string(from: session.createdAt)
            return "\(dateStr), \(startStr) – \(endStr)"
        }

        return "\(startStr) – \(endStr)"
    }

    /// Active (blocking) time for a session, counting only the part inside the selected period
    /// so rows add up to the headline total
    private func sessionActiveTime(_ session: BlockSession) -> TimeInterval {
        StatsManager.shared.totals(for: session, period: selectedPeriod, offset: offset).active
    }

    @ViewBuilder
    private func reasonBadge(for reason: EndReason) -> some View {
        let (text, color): (String, Color) = switch reason {
        case .completed:
            ("Completed", .green)
        case .exited:
            ("Exited", .red)
        case .cancelled:
            ("Cancelled", .orange)
        case .error:
            ("Interrupted", .gray)
        }

        badge(text, color: color)
    }

    /// Badge for a session that hasn't ended yet
    @ViewBuilder
    private func stateBadge(for state: BlockState) -> some View {
        switch state {
        case .snoozed:
            badge("Snoozed", color: .orange)
        case .sleeping:
            badge("Sleeping", color: .blue)
        case .active, .ended:
            badge("Active", color: .blue)
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundColor(color)
            .cornerRadius(4)
    }
}
