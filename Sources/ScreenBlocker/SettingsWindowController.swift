import AppKit
import SwiftUI

class SettingsWindowController: NSWindowController {
    convenience init() {
        let settingsView = SettingsView()
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
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
    @ObservedObject private var manager = ScheduleManager.shared
    @State private var selectedSchedule: Schedule?
    @State private var isEditing = false

    var body: some View {
        HSplitView {
            // Schedule list
            VStack(alignment: .leading, spacing: 0) {
                List(selection: $selectedSchedule) {
                    ForEach(manager.schedules) { schedule in
                        ScheduleRow(schedule: schedule)
                            .tag(schedule)
                    }
                }
                .listStyle(.sidebar)

                Divider()

                HStack {
                    Button(action: addSchedule) {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)

                    Button(action: removeSelectedSchedule) {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(selectedSchedule == nil)

                    Spacer()
                }
                .padding(8)
            }
            .frame(minWidth: 200, maxWidth: 250)

            // Schedule editor
            VStack {
                if let schedule = selectedSchedule {
                    ScheduleEditorView(schedule: binding(for: schedule))
                } else {
                    Text("Select a schedule to edit")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                Divider()

                // Global settings
                VStack(alignment: .leading, spacing: 12) {
                    Text("Notification Settings")
                        .font(.headline)

                    HStack {
                        Text("Notify before block:")
                        Picker("", selection: $manager.notificationLeadTime) {
                            Text("Off").tag(0)
                            Text("1 minute").tag(1)
                            Text("5 minutes").tag(5)
                            Text("10 minutes").tag(10)
                            Text("15 minutes").tag(15)
                        }
                        .labelsHidden()
                        .frame(width: 120)
                        .onChange(of: manager.notificationLeadTime) { _ in
                            manager.saveSettings()
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 350)
        }
        .frame(minWidth: 550, minHeight: 400)
    }

    private func addSchedule() {
        let newSchedule = Schedule()
        manager.addSchedule(newSchedule)
        selectedSchedule = newSchedule
    }

    private func removeSelectedSchedule() {
        guard let schedule = selectedSchedule else { return }
        manager.deleteSchedule(schedule)
        selectedSchedule = manager.schedules.first
    }

    private func binding(for schedule: Schedule) -> Binding<Schedule> {
        Binding(
            get: {
                manager.schedules.first { $0.id == schedule.id } ?? schedule
            },
            set: { newValue in
                manager.updateSchedule(newValue)
                selectedSchedule = newValue
            }
        )
    }
}

struct ScheduleRow: View {
    let schedule: Schedule

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(schedule.name)
                    .fontWeight(.medium)

                Spacer()

                if !schedule.isEnabled {
                    Text("OFF")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Text("\(schedule.startTimeString) - \(schedule.endTimeString)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct ScheduleEditorView: View {
    @Binding var schedule: Schedule

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $schedule.name)

                Toggle("Enabled", isOn: $schedule.isEnabled)
            }

            Section("Time") {
                HStack {
                    Text("Start:")
                    TimePicker(hour: $schedule.startHour, minute: $schedule.startMinute)

                    Spacer().frame(width: 40)

                    Text("End:")
                    TimePicker(hour: $schedule.endHour, minute: $schedule.endMinute)
                }
            }

            Section("Days") {
                HStack(spacing: 8) {
                    ForEach(Weekday.allCases, id: \.self) { day in
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
                    Button("Weekdays Only") {
                        schedule.enabledDays = Set([.monday, .tuesday, .wednesday, .thursday, .friday])
                    }
                    .buttonStyle(.borderless)

                    Button("Weekends Only") {
                        schedule.enabledDays = Set([.saturday, .sunday])
                    }
                    .buttonStyle(.borderless)

                    Button("Every Day") {
                        schedule.enabledDays = Set(Weekday.allCases)
                    }
                    .buttonStyle(.borderless)
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
    @Binding var hour: Int
    @Binding var minute: Int

    var body: some View {
        HStack(spacing: 2) {
            Picker("", selection: $hour) {
                ForEach(0..<24, id: \.self) { h in
                    Text(String(format: "%d", h)).tag(h)
                }
            }
            .labelsHidden()
            .frame(width: 60)

            Text(":")

            Picker("", selection: $minute) {
                ForEach([0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55], id: \.self) { m in
                    Text(String(format: "%02d", m)).tag(m)
                }
            }
            .labelsHidden()
            .frame(width: 60)
        }
    }
}

struct DayToggle: View {
    let day: Weekday
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            Text(day.initial)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(isSelected ? Color.accentColor : Color.gray.opacity(0.2))
                )
                .foregroundColor(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
        .help(day.shortName)
    }
}
