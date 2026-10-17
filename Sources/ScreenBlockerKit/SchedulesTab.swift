import SwiftUI

struct SchedulesTab: View {
    @ObservedObject private var manager = ScheduleManager.shared
    @State private var selectedScheduleID: UUID?
    @State private var showDeleteConfirmation = false

    private var selectedSchedule: Schedule? {
        guard let id = selectedScheduleID else { return nil }
        return manager.schedules.first { $0.id == id }
    }

    var body: some View {
        HSplitView {
            // Schedule list
            VStack(alignment: .leading, spacing: 0) {
                List(selection: $selectedScheduleID) {
                    ForEach(manager.schedules) { schedule in
                        ScheduleRow(schedule: schedule)
                            .tag(schedule.id)
                    }
                }
                .listStyle(.sidebar)
                .onAppear {
                    if selectedScheduleID == nil {
                        selectedScheduleID = manager.schedules.first?.id
                    }
                }
                .onDeleteCommand {
                    if selectedSchedule != nil {
                        showDeleteConfirmation = true
                    }
                }

                Divider()

                HStack {
                    Button(action: addSchedule) {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("Add Schedule")
                    .accessibilityLabel("Add Schedule")

                    Button(action: { showDeleteConfirmation = true }) {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(selectedSchedule == nil)
                    .help("Delete Schedule")
                    .accessibilityLabel("Delete Schedule")

                    Spacer()
                }
                .padding(8)
            }
            .frame(minWidth: 200, maxWidth: 250)
            .alert("Delete Schedule", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) {
                    removeSelectedSchedule()
                }
            } message: {
                if let schedule = selectedSchedule {
                    Text("Are you sure you want to delete \"\(schedule.displayName)\"?")
                }
            }

            // Schedule editor
            VStack {
                if let schedule = selectedSchedule {
                    ScheduleEditorView(schedule: binding(for: schedule))
                } else if manager.schedules.isEmpty {
                    VStack(spacing: 6) {
                        Text("No Schedules")
                            .font(.title3)
                        Text("Click + to add a schedule.")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text("Select a schedule to edit")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 400)
        }
    }

    private func addSchedule() {
        let newSchedule = Schedule()
        manager.addSchedule(newSchedule)
        selectedScheduleID = newSchedule.id
    }

    private func removeSelectedSchedule() {
        guard let schedule = selectedSchedule else { return }
        manager.deleteSchedule(schedule)
        selectedScheduleID = manager.schedules.first?.id
    }

    private func binding(for schedule: Schedule) -> Binding<Schedule> {
        Binding(
            get: {
                manager.schedules.first { $0.id == schedule.id } ?? schedule
            },
            set: { newValue in
                manager.updateSchedule(newValue)
            }
        )
    }
}

struct ScheduleRow: View {
    let schedule: Schedule

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(schedule.displayName)
                    .fontWeight(.medium)

                Spacer()

                if !schedule.isEnabled {
                    Text("OFF")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Text(schedule.timeRangeString)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct ScheduleEditorView: View {
    @Binding var schedule: Schedule
    @ObservedObject private var manager = ScheduleManager.shared

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $schedule.name)

                TextField("Message", text: $schedule.message)

                Toggle("Enabled", isOn: $schedule.isEnabled)
            }

            Section("Time") {
                HStack {
                    Text("Start:")
                    TimePicker(label: "Start time", hour: $schedule.startHour, minute: $schedule.startMinute)

                    Spacer().frame(width: 40)

                    Text("End:")
                    TimePicker(label: "End time", hour: $schedule.endHour, minute: $schedule.endMinute)
                }
            }

            Section("Days") {
                HStack(spacing: 8) {
                    ForEach(Weekday.orderedForCurrentCalendar, id: \.self) { day in
                        DayToggle(
                            day: day,
                            isSelected: schedule.enabledDays.contains(day),
                            onToggle: { toggleDay(day) }
                        )
                    }
                }
            }

            Section {
                HStack {
                    Button("Weekdays") {
                        schedule.enabledDays = Set([.monday, .tuesday, .wednesday, .thursday, .friday])
                    }

                    Button("Weekends") {
                        schedule.enabledDays = Set([.saturday, .sunday])
                    }

                    Button("Every Day") {
                        schedule.enabledDays = Set(Weekday.allCases)
                    }
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Button("Resume Block") {
                        manager.startManualBlock(from: schedule)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!manager.canResume(schedule))

                    Text("Picks this block back up after exiting or snoozing it. Available during its scheduled time.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func toggleDay(_ day: Weekday) {
        if schedule.enabledDays.contains(day) {
            schedule.enabledDays.remove(day)
        } else {
            schedule.enabledDays.insert(day)
        }
    }
}

struct TimePicker: View {
    let label: String
    @Binding var hour: Int
    @Binding var minute: Int

    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                // A fixed date rather than today, so times skipped by a DST change can still be picked
                let components = DateComponents(year: 2001, month: 1, day: 1, hour: hour, minute: minute)
                return Calendar.current.date(from: components) ?? Date()
            },
            set: { newDate in
                let components = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                hour = components.hour ?? 0
                minute = components.minute ?? 0
            }
        )
    }

    var body: some View {
        DatePicker(label, selection: timeBinding, displayedComponents: .hourAndMinute)
            .labelsHidden()
    }
}

struct DayToggle: View {
    let day: Weekday
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            Text(day.shortName)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 36, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Color.accentColor : Color.gray.opacity(0.2))
                )
                .foregroundColor(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.fullName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
