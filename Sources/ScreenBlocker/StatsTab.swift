import SwiftUI

struct StatsTab: View {
    @State private var selectedPeriod: StatsPeriod = .day
    @State private var offset: Int = 0
    @State private var sessions: [BlockSession] = []
    @State private var totals: BlockTotals = BlockTotals()

    // Cached formatters (DateFormatter is expensive to create)
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 20) {
            // Period selector
            Picker("", selection: $selectedPeriod) {
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

                    Text(selectedPeriod.formatLabel(for: Date(), offset: offset))
                        .font(.headline)
                        .frame(minWidth: 150)

                    Button(action: { offset += 1; loadStats() }) {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.borderless)
                    .disabled(offset >= 0)
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
                                Text("Active")
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.2))
                                    .foregroundColor(.blue)
                                    .cornerRadius(4)
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
        totals = StatsManager.shared.totals(for: selectedPeriod, offset: offset)
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
        let endTime = session.events.last?.timestamp ?? session.createdAt
        let endStr = Self.timeFormatter.string(from: endTime)

        if selectedPeriod != .day {
            let dateStr = Self.dateFormatter.string(from: session.createdAt)
            return "\(dateStr), \(startStr) – \(endStr)"
        }

        return "\(startStr) – \(endStr)"
    }

    /// Calculate only the active (blocking) time for a session
    private func sessionActiveTime(_ session: BlockSession) -> TimeInterval {
        var activeTime: TimeInterval = 0
        let events = session.events

        for i in 0..<events.count {
            let event = events[i]
            guard event.state == .active else { continue }

            let nextTimestamp: Date
            if i + 1 < events.count {
                nextTimestamp = events[i + 1].timestamp
            } else {
                nextTimestamp = Date()
            }

            activeTime += nextTimestamp.timeIntervalSince(event.timestamp)
        }

        return activeTime
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
            ("Error", .gray)
        }

        Text(text)
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundColor(color)
            .cornerRadius(4)
    }
}
