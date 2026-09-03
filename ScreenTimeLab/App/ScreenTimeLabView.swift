import FamilyControls
import Foundation
import SwiftData
import SwiftUI

struct ScreenTimeLabView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = ScreenTimeLabModel()
    @State private var isPickerPresented = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Authorization") {
                    LabeledContent("Status", value: String(describing: model.authorizationStatus))
                    Button("Request individual authorization") {
                        Task { await model.requestAuthorization() }
                    }
                }

                Section("Profile") {
                    TextField("Profile name", text: $model.profileName)
                        .textInputAutocapitalization(.words)
                    Button("Save profile") {
                        model.persistProfile()
                    }
                }

                Section("Selection") {
                    LabeledContent("Applications", value: "\(model.selection.applicationTokens.count)")
                    LabeledContent("Categories", value: "\(model.selection.categoryTokens.count)")
                    LabeledContent("Web domains", value: "\(model.selection.webDomainTokens.count)")
                    Button("Choose apps, categories and sites") {
                        isPickerPresented = true
                    }
                    .disabled(model.authorizationStatus != .approved)
                }

                Section("Local schedule") {
                    Toggle("Enabled", isOn: $model.scheduleEnabled)
                    ForEach(ScheduleWeekday.allCases, id: \.self) { day in
                        Toggle(day.rawValue, isOn: Binding(
                            get: { model.selectedScheduleWeekdays.contains(day) },
                            set: { enabled in
                                if enabled {
                                    model.selectedScheduleWeekdays.insert(day)
                                } else {
                                    model.selectedScheduleWeekdays.remove(day)
                                }
                            }))
                    }
                    Picker("Start hour", selection: $model.scheduleStartHour) {
                        ForEach(0..<24, id: \.self) { hour in
                            Text(String(format: "%02d:00", hour)).tag(hour)
                        }
                    }
                    Picker("Start minute", selection: $model.scheduleStartMinute) {
                        ForEach([0, 15, 30, 45], id: \.self) { minute in
                            Text(String(format: ":%02d", minute)).tag(minute)
                        }
                    }
                    Picker("End hour", selection: $model.scheduleEndHour) {
                        ForEach(0..<24, id: \.self) { hour in
                            Text(String(format: "%02d:00", hour)).tag(hour)
                        }
                    }
                    Picker("End minute", selection: $model.scheduleEndMinute) {
                        ForEach([0, 15, 30, 45], id: \.self) { minute in
                            Text(String(format: ":%02d", minute)).tag(minute)
                        }
                    }
                    Picker("DST policy", selection: $model.selectedScheduleDstPolicy) {
                        ForEach(ScheduleDstPolicy.allCases, id: \.self) { policy in
                            Text(policy.rawValue).tag(policy)
                        }
                    }
                    LabeledContent("Time zone", value: TimeZone.current.identifier)
                    if let nextStart = model.nextScheduleStart,
                       let nextEnd = model.nextScheduleEnd {
                        LabeledContent("Next window") {
                            VStack(alignment: .trailing) {
                                Text(nextStart, format: .dateTime.year().month().day().hour().minute())
                                Text(nextEnd, format: .dateTime.hour().minute())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text("No valid window is available in the next 30 days.")
                            .foregroundStyle(.secondary)
                    }
                    Button("Save local schedule") {
                        model.persistSchedule()
                    }
                    Text("This lab stores and previews the local window. DeviceActivity scheduler delivery still requires the signed Codemagic/iPhone gate.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Session") {
                    Toggle("Strict Mode", isOn: $model.strictModeEnabled)
                        .disabled(model.isSessionActive)
                    Text("This lab prevents the normal stop action only. Settings, permission revocation and system-level escape paths remain outside the guarantee.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    LabeledContent("State", value: model.isSessionActive ? "Active" : "Idle")
                    if let endDate = model.sessionEndDate, model.isSessionActive {
                        LabeledContent("Remaining", value: endDate, format: .dateTime.hour().minute().second())
                        Text(endDate, style: .timer)
                            .font(.title2.monospacedDigit())
                            .frame(maxWidth: .infinity, alignment: .center)
                            .accessibilityLabel("Session countdown")
                    }
                    Button("Start 10-minute session") {
                        model.startTenMinuteSession()
                    }
                    .disabled(model.authorizationStatus != .approved || model.isSessionActive)
                    Button("Stop session", role: .destructive) {
                        model.stopSession()
                    }
                    .disabled(!model.isSessionActive || model.strictModeEnabled)
                }

                if let errorMessage = model.errorMessage {
                    Section("Diagnostic") {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Screen Time Lab")
        }
        .familyActivityPicker(isPresented: $isPickerPresented, selection: $model.selection)
        .task {
            model.configurePersistence(modelContext)
            model.restoreProfile()
            model.restoreSelection()
            model.restoreStrictModeSetting()
            model.restoreSchedule()
            model.restoreSessionState()
            model.refreshAuthorizationStatus()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            model.restoreSchedule()
            model.restoreSessionState()
            model.refreshAuthorizationStatus()
        }
    }
}

#Preview {
    ScreenTimeLabView()
}
