import SwiftUI

struct StatsTab: View {
    @State private var selectedPeriod: StatsPeriod = .day
    @State private var offset: Int = 0
    @State private var records: [BlockRecord] = []
    @State private var totalDuration: TimeInterval = 0

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

            // Total duration
            VStack(spacing: 4) {
                Text("Total Block Time")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Text(formatDuration(totalDuration))
                    .font(.system(size: 48, weight: .medium, design: .rounded))
            }
            .padding(.vertical, 20)

            Divider()

            // Records list
            if records.isEmpty {
                Text("No blocks recorded for this period")
                    .foregroundColor(.secondary)
                    .frame(maxHeight: .infinity)
            } else {
                List(records) { record in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.scheduleName)
                                .fontWeight(.medium)
                            Text(formatRecordTime(record))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        HStack(spacing: 8) {
                            Text(formatDuration(record.duration))
                                .font(.system(.body, design: .monospaced))

                            reasonBadge(for: record.reason)
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
        let (startDate, endDate) = selectedPeriod.dateRange(from: Date(), offset: offset)
        let loadedRecords = StatsManager.shared.records(for: selectedPeriod, offset: offset)

        records = loadedRecords.sorted { $0.start > $1.start }

        // Compute total from already-loaded records (avoids re-reading files)
        totalDuration = loadedRecords.reduce(0) { total, record in
            let clampedStart = max(record.start, startDate)
            let clampedEnd = min(record.end, endDate)
            return total + clampedEnd.timeIntervalSince(clampedStart)
        }
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

    private func formatRecordTime(_ record: BlockRecord) -> String {
        let startStr = Self.timeFormatter.string(from: record.start)
        let endStr = Self.timeFormatter.string(from: record.end)

        if selectedPeriod != .day {
            let dateStr = Self.dateFormatter.string(from: record.start)
            return "\(dateStr), \(startStr) – \(endStr)"
        }

        return "\(startStr) – \(endStr)"
    }

    @ViewBuilder
    private func reasonBadge(for reason: BlockEndReason) -> some View {
        let (text, color): (String, Color) = switch reason {
        case .completed:
            ("Completed", .green)
        case .postponed:
            ("Postponed", .orange)
        case .exited:
            ("Exited", .red)
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
