import DeviceActivity
import FamilyControls
import FocusGuardDomain
import Foundation
import ManagedSettings
import SwiftData
import SwiftUI

@MainActor
final class ScreenTimeLabModel: ObservableObject {
    @Published var profileName = "Screen Time Lab"
    @Published var selection = FamilyActivitySelection()
    @Published private(set) var authorizationStatus = AuthorizationCenter.shared.authorizationStatus
    @Published private(set) var isSessionActive = false
    @Published private(set) var sessionEndDate: Date?
    @Published var strictModeEnabled = false
    @Published var scheduleEnabled = false
    @Published var scheduleStartHour = 8
    @Published var scheduleStartMinute = 30
    @Published var scheduleEndHour = 12
    @Published var scheduleEndMinute = 0
    @Published var selectedScheduleDstPolicy: ScheduleDstPolicy = .shiftForward
    @Published var selectedScheduleWeekdays: Set<ScheduleWeekday> = [
        .monday, .tuesday, .wednesday, .thursday, .friday
    ]
    @Published private(set) var nextScheduleStart: Date?
    @Published private(set) var nextScheduleEnd: Date?
    @Published var errorMessage: String?

    private let authorizationCenter = AuthorizationCenter.shared
    private let activityCenter = DeviceActivityCenter()
    private let settingsStore = ManagedSettingsStore(
        named: ManagedSettingsStore.Name(ScreenTimeLabConstants.activityName))
    private let defaults = UserDefaults(suiteName: ScreenTimeLabConstants.appGroup)
    private var modelContext: ModelContext?
    private var profileID: UUID?
    private var activeSessionID: UUID?
    private var scheduleID: UUID?
    private(set) var syncStore: ScreenTimeSyncStore?

    func configurePersistence(_ context: ModelContext) {
        modelContext = context
        if let deviceID = try? FocusGuardDeviceIdentity.loadOrCreate() {
            syncStore = ScreenTimeSyncStore(modelContext: context, deviceID: deviceID)
        }
    }

    func requestAuthorization() async {
        do {
            try await authorizationCenter.requestAuthorization(for: .individual)
            authorizationStatus = authorizationCenter.authorizationStatus
            errorMessage = nil
        } catch {
            errorMessage = "Authorization failed: \(error.localizedDescription)"
        }
    }

    func refreshAuthorizationStatus() {
        authorizationStatus = authorizationCenter.authorizationStatus
    }

    func restoreSessionState() {
        let storedSession: LocalSessionRecord?
        if let modelContext {
            storedSession = try? modelContext.fetch(FetchDescriptor<LocalSessionRecord>())
                .filter { $0.stateRaw == "Active" || $0.stateRaw == "Activating" }
                .sorted { $0.updatedAt > $1.updatedAt }
                .first
        } else {
            storedSession = nil
        }
        let endDate = storedSession?.endDate
            ?? defaults?.object(forKey: ScreenTimeLabConstants.sessionEndKey) as? Date
        guard let endDate else {
            isSessionActive = false
            sessionEndDate = nil
            activeSessionID = nil
            return
        }

        guard endDate > .now else {
            stopSession(force: true)
            return
        }

        sessionEndDate = endDate
        isSessionActive = true
        if let storedSession {
            activeSessionID = storedSession.id
            strictModeEnabled = storedSession.strictModeEnabled
            storedSession.stateRaw = "Active"
            storedSession.updatedAt = .now
            try? modelContext?.save()
        }
        // Re-assert the local shield after a normal app relaunch. The monitor
        // extension remains the independent path while this process is closed.
        applyShield()
    }

    func restoreProfile() {
        guard let modelContext,
              let profile = (try? modelContext.fetch(FetchDescriptor<LocalProfileRecord>()))?
                .sorted(by: { $0.updatedAt > $1.updatedAt })
                .first else {
            return
        }
        profileID = profile.id
        profileName = profile.name
    }

    @discardableResult
    func persistProfile() -> Bool {
        let normalizedName = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            errorMessage = "Profile name is required."
            return false
        }
        profileName = normalizedName
        guard let modelContext else {
            profileID = profileID ?? UUID()
            errorMessage = nil
            return true
        }

        do {
            let record: LocalProfileRecord
            if let profileID,
               let existing = (try modelContext.fetch(FetchDescriptor<LocalProfileRecord>()))
                .first(where: { $0.id == profileID }) {
                record = existing
            } else {
                record = LocalProfileRecord(name: normalizedName)
                modelContext.insert(record)
                profileID = record.id
            }
            record.name = normalizedName
            record.updatedAt = .now
            try modelContext.save()
            errorMessage = nil
            return true
        } catch {
            errorMessage = "The local profile could not be saved: \(error.localizedDescription)"
            return false
        }
    }

    func restoreSelection() {
        guard let data = defaults?.data(forKey: ScreenTimeLabConstants.selectionKey),
              let saved = try? PropertyListDecoder().decode(FamilyActivitySelection.self, from: data) else {
            return
        }
        selection = saved
    }

    @discardableResult
    func persistSelection() -> Bool {
        guard let defaults else {
            errorMessage = "The App Group container is unavailable; the selection cannot be persisted."
            return false
        }
        guard let data = try? PropertyListEncoder().encode(selection) else {
            errorMessage = "The local Screen Time selection could not be encoded."
            return false
        }
        defaults.set(data, forKey: ScreenTimeLabConstants.selectionKey)
        return true
    }

    func restoreStrictModeSetting() {
        strictModeEnabled = defaults?.bool(forKey: ScreenTimeLabConstants.strictModeKey) ?? false
    }

    func restoreSchedule() {
        guard let modelContext,
              let record = (try? modelContext.fetch(FetchDescriptor<LocalScheduleRecord>()))?
                .sorted(by: { $0.updatedAt > $1.updatedAt })
                .first else {
            refreshSchedulePreview()
            return
        }

        scheduleID = record.id
        scheduleEnabled = record.isEnabled
        selectedScheduleDstPolicy = ScheduleDstPolicy(rawValue: record.dstPolicyRaw) ?? .shiftForward
        scheduleStartHour = record.startSeconds / 3_600
        scheduleStartMinute = (record.startSeconds % 3_600) / 60
        scheduleEndHour = record.endSeconds / 3_600
        scheduleEndMinute = (record.endSeconds % 3_600) / 60
        selectedScheduleWeekdays = Set(record.weekdaysRaw.split(separator: ",").compactMap {
            ScheduleWeekday(rawValue: String($0))
        })
        refreshSchedulePreview()
    }

    @discardableResult
    func persistSchedule() -> Bool {
        guard persistProfile(), let profileID else { return false }
        guard !selectedScheduleWeekdays.isEmpty else {
            errorMessage = "Choose at least one schedule day."
            return false
        }

        do {
            let schedule = try makeLocalSchedule(profileID: profileID)
            if let modelContext {
                let record: LocalScheduleRecord
                if let scheduleID,
                   let existing = (try modelContext.fetch(FetchDescriptor<LocalScheduleRecord>()))
                    .first(where: { $0.id == scheduleID }) {
                    record = existing
                } else {
                    record = LocalScheduleRecord(
                        profileID: profileID,
                        timeZoneID: schedule.timeZoneID)
                    modelContext.insert(record)
                    scheduleID = record.id
                }
                record.profileID = profileID
                record.timeZoneID = schedule.timeZoneID
                record.dstPolicyRaw = schedule.dstPolicy.rawValue
                record.weekdaysRaw = selectedScheduleWeekdays
                    .sorted { $0.rawValue < $1.rawValue }
                    .map(\.rawValue)
                    .joined(separator: ",")
                record.startSeconds = schedule.startLocal.hour * 3_600
                    + schedule.startLocal.minute * 60
                    + schedule.startLocal.second
                record.endSeconds = schedule.endLocal.hour * 3_600
                    + schedule.endLocal.minute * 60
                    + schedule.endLocal.second
                record.isEnabled = schedule.isEnabled
                record.updatedAt = .now
                try modelContext.save()
            }
            refreshSchedulePreview(schedule)
            errorMessage = nil
            return true
        } catch {
            errorMessage = "The local schedule could not be saved: \(error.localizedDescription)"
            return false
        }
    }

    func persistStrictModeSetting() {
        defaults?.set(strictModeEnabled, forKey: ScreenTimeLabConstants.strictModeKey)
    }

    func startTenMinuteSession() {
        guard authorizationStatus == .approved else {
            errorMessage = "Approve Family Controls before starting a session."
            return
        }

        guard defaults != nil else {
            errorMessage = "The App Group container is unavailable; the session cannot be started safely."
            return
        }

        guard persistSelection(), persistProfile(), let profileID else { return }
        persistStrictModeSetting()
        let start = Date()
        let end = start.addingTimeInterval(10 * 60)
        let sessionID = UUID()
        activeSessionID = sessionID
        defaults?.set(sessionID.uuidString, forKey: ScreenTimeLabConstants.sessionIDKey)
        defaults?.set(start, forKey: ScreenTimeLabConstants.sessionStartKey)
        defaults?.set(end, forKey: ScreenTimeLabConstants.sessionEndKey)
        let localSession = LocalSessionRecord(
            id: sessionID,
            profileID: profileID,
            stateRaw: "Active",
            startDate: start,
            endDate: end,
            strictModeEnabled: strictModeEnabled)
        modelContext?.insert(localSession)

        let calendar = Calendar.current
        let schedule = DeviceActivitySchedule(
            intervalStart: calendar.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: start),
            intervalEnd: calendar.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: end),
            repeats: false)
        do {
            if let modelContext {
                try modelContext.save()
            }
            applyShield()
            try activityCenter.startMonitoring(
                DeviceActivityName(ScreenTimeLabConstants.activityName),
                during: schedule)
            isSessionActive = true
            sessionEndDate = end
            errorMessage = nil
        } catch {
            settingsStore.clearAllSettings()
            if let modelContext {
                modelContext.delete(localSession)
                try? modelContext.save()
            }
            defaults?.removeObject(forKey: ScreenTimeLabConstants.sessionIDKey)
            defaults?.removeObject(forKey: ScreenTimeLabConstants.sessionStartKey)
            defaults?.removeObject(forKey: ScreenTimeLabConstants.sessionEndKey)
            activeSessionID = nil
            errorMessage = "Device Activity monitoring failed: \(error.localizedDescription)"
        }
    }

    func stopSession(force: Bool = false) {
        if isSessionActive && strictModeEnabled && !force {
            errorMessage = "Strict Mode keeps this session active until its deadline."
            return
        }
        activityCenter.stopMonitoring([DeviceActivityName(ScreenTimeLabConstants.activityName)])
        settingsStore.clearAllSettings()
        if let modelContext,
           let sessionID = activeSessionID
                ?? defaults?.string(forKey: ScreenTimeLabConstants.sessionIDKey).flatMap(UUID.init(uuidString:)),
           let record = (try? modelContext.fetch(FetchDescriptor<LocalSessionRecord>()))?.first(where: { $0.id == sessionID }) {
            record.stateRaw = force ? "Expired" : "Stopped"
            record.updatedAt = .now
            try? modelContext?.save()
        }
        defaults?.removeObject(forKey: ScreenTimeLabConstants.sessionIDKey)
        defaults?.removeObject(forKey: ScreenTimeLabConstants.sessionStartKey)
        defaults?.removeObject(forKey: ScreenTimeLabConstants.sessionEndKey)
        isSessionActive = false
        sessionEndDate = nil
        activeSessionID = nil
        errorMessage = nil
    }

    private func applyShield() {
        settingsStore.shield.applications = selection.applicationTokens.isEmpty
            ? nil
            : selection.applicationTokens
        settingsStore.shield.webDomains = selection.webDomainTokens.isEmpty
            ? nil
            : selection.webDomainTokens
        settingsStore.shield.applicationCategories = selection.categoryTokens.isEmpty
            ? nil
            : .specific(selection.categoryTokens)
    }

    private func makeLocalSchedule(profileID: UUID) throws -> FocusSchedule {
        try FocusSchedule(
            profileID: ProfileID(rawValue: profileID),
            timeZoneID: TimeZone.current.identifier,
            dstPolicy: selectedScheduleDstPolicy,
            weekdays: selectedScheduleWeekdays,
            startLocal: try LocalTimeOfDay(hour: scheduleStartHour, minute: scheduleStartMinute),
            endLocal: try LocalTimeOfDay(hour: scheduleEndHour, minute: scheduleEndMinute),
            isEnabled: scheduleEnabled)
    }

    private func refreshSchedulePreview(_ schedule: FocusSchedule? = nil) {
        guard let schedule = schedule ?? (try? makeLocalSchedule(profileID: profileID ?? UUID())) else {
            nextScheduleStart = nil
            nextScheduleEnd = nil
            return
        }
        let now = Date()
        let horizon = now.addingTimeInterval(30 * 24 * 60 * 60)
        let window = FocusScheduleMaterializer.materialize(
            schedule: schedule,
            from: now,
            through: horizon,
            maximumOccurrences: 1).first
        nextScheduleStart = window?.start
        nextScheduleEnd = window?.end
    }
}
