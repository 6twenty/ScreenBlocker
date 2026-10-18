import SwiftUI

struct SchedulesTab: View {
    @ObservedObject private var manager = ScheduleManager.shared
    @ObservedObject private var pinLock = PinLock.shared
    @State private var selectedScheduleID: UUID?
    @State private var scheduleIDPendingDeletion: UUID?  // Captured when the confirmation opens

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
                    if pinLock.canEditSettings, let schedule = selectedSchedule {
                        scheduleIDPendingDeletion = schedule.id
                    }
                }

                Divider()

                HStack {
                    Button(action: addSchedule) {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!pinLock.canEditSettings)
                    .help("Add Schedule")
                    .accessibilityLabel("Add Schedule")

                    Button(action: { scheduleIDPendingDeletion = selectedSchedule?.id }) {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(selectedSchedule == nil || !pinLock.canEditSettings)
                    .help("Delete Schedule")
                    .accessibilityLabel("Delete Schedule")

                    Spacer()
                }
                .padding(8)
            }
            .frame(minWidth: 200, maxWidth: 250)
            .alert("Delete Schedule", isPresented: Binding(
                get: { scheduleIDPendingDeletion != nil },
                set: { if !$0 { scheduleIDPendingDeletion = nil } }
            )) {
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) {
                    if let id = scheduleIDPendingDeletion {
                        removeSchedule(id)
                    }
                }
            } message: {
                if let schedule = manager.schedules.first(where: { $0.id == scheduleIDPendingDeletion }) {
                    Text("Are you sure you want to delete \"\(schedule.displayName)\"?")
                }
            }

            // Schedule editor
            VStack {
                if let schedule = selectedSchedule {
                    ScheduleEditorView(schedule: binding(for: schedule), isLocked: !pinLock.canEditSettings)
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
        guard pinLock.canEditSettings else { return }
        let newSchedule = Schedule()
        manager.addSchedule(newSchedule)
        selectedScheduleID = newSchedule.id
    }

    private func removeSchedule(_ id: UUID) {
        guard pinLock.canEditSettings, let schedule = manager.schedules.first(where: { $0.id == id }) else { return }
        manager.deleteSchedule(schedule)
        if selectedScheduleID == id {
            selectedScheduleID = manager.schedules.first?.id
        }
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
    /// The PIN is on and Settings are locked. Resume Block stays available.
    let isLocked: Bool
    @ObservedObject private var manager = ScheduleManager.shared

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $schedule.name)

                TextField("Message", text: $schedule.message)

                Toggle("Enabled", isOn: $schedule.isEnabled)
            }
            .disabled(isLocked)

            Section {
                Toggle("Allow snooze", isOn: $schedule.allowsSnooze)
                Text(manager.snoozeDuration > 0
                     ? "Each block can be snoozed once, for \(ScheduleManager.describeMinutes(manager.snoozeDuration)), which moves its end time back to match. When blocks overlap, all of them must allow it."
                     : "Snoozing is turned off in General settings.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .disabled(isLocked)

            Section("Time") {
                HStack {
                    Text("Start:")
                    TimePicker(label: "Start time", hour: $schedule.startHour, minute: $schedule.startMinute)

                    Spacer().frame(width: 40)

                    Text("End:")
                    TimePicker(label: "End time", hour: $schedule.endHour, minute: $schedule.endMinute)
                }

                if schedule.hasEqualStartAndEnd {
                    Label("Start and end are the same, so this blocks for 24 hours.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }
            .disabled(isLocked)

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
            .disabled(isLocked)

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
            .disabled(isLocked)

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Button("Resume Block", action: resume)
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

    private func resume() {
        manager.checkSchedules()
        guard PinLock.shared.isEnabled && manager.resumeReplacesSnoozedBlock(schedule) else {
            manager.startManualBlock(from: schedule)
            return
        }
        let snoozedBlockID = manager.currentBlockID
        let pin = PinPrompt.requestPin(
            title: "Resume Block?",
            message: "Another block is snoozed. Resuming this one replaces it and drops its remaining time, so it needs your PIN.",
            cancelIf: { !manager.isSnoozed || manager.currentBlockID != snoozedBlockID }
        )
        if pin != nil {
            manager.startManualBlock(from: schedule, replacingSnoozedBlock: snoozedBlockID)
        }
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
