import SwiftUI

/// Settings rows for what may notify: kinds, quiet hours and the muted agents. Shared by iOS
/// Settings and the Mac's Notifications tab; every change goes through `Delivery.prefs`, which
/// also re-registers with the helpers.
struct NotificationPrefsSection: View {
    @State private var prefs = Delivery.prefs

    var body: some View {
        Section {
            Toggle("Needs you", isOn: edit(\.needsYou))
            Toggle("Finished", isOn: edit(\.finished))
            Toggle("Errors", isOn: edit(\.errors))
        } header: {
            Text("Notify me when an agent")
        } footer: {
            Text("Turn off the kinds you don't want. Muting one agent is in its context menu.")
        }

        Section {
            Toggle("Quiet hours", isOn: edit(\.quietEnabled))
            if prefs.quietEnabled {
                DatePicker("From", selection: time(\.quietStart), displayedComponents: .hourAndMinute)
                DatePicker("To", selection: time(\.quietEnd), displayedComponents: .hourAndMinute)
            }
        } footer: {
            Text("During quiet hours only \"Needs you\" notifies. Finished and error alerts are held back, and a summary arrives when quiet hours end.")
        }

        Section {
            Toggle("Keep machines awake while agents work", isOn: edit(\.keepAwake))
        } footer: {
            Text("The helper on each machine stops it sleeping while an agent is working, and lets go two minutes after the last one stops.")
        }

        if !prefs.muted.isEmpty {
            Section("Muted agents") {
                ForEach(prefs.muted.sorted { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }, id: \.key) { entry in
                    HStack {
                        Text(entry.value)
                        Spacer()
                        Button("Unmute") {
                            var next = prefs
                            next.muted[entry.key] = nil
                            set(next)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private func set(_ next: NotificationPrefs) {
        prefs = next
        Delivery.prefs = next
    }

    private func edit(_ path: WritableKeyPath<NotificationPrefs, Bool>) -> Binding<Bool> {
        Binding(get: { prefs[keyPath: path] }, set: { value in
            var next = prefs
            next[keyPath: path] = value
            set(next)
        })
    }

    private func time(_ path: WritableKeyPath<NotificationPrefs, Int>) -> Binding<Date> {
        Binding(get: {
            Calendar.current.date(bySettingHour: prefs[keyPath: path] / 60, minute: prefs[keyPath: path] % 60,
                                  second: 0, of: Date()) ?? Date()
        }, set: { date in
            var next = prefs
            next[keyPath: path] = NotificationPrefs.minute(of: date)
            set(next)
        })
    }
}
