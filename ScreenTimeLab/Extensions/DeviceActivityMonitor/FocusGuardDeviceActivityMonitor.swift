import DeviceActivity
import FamilyControls
import ManagedSettings

final class FocusGuardDeviceActivityMonitor: DeviceActivityMonitor {
    private let store = ManagedSettingsStore(
        named: ManagedSettingsStore.Name(ScreenTimeLabConstants.activityName))
    private let defaults = UserDefaults(suiteName: ScreenTimeLabConstants.appGroup)

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        applyPersistedSelection()
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        store.clearAllSettings()
        defaults?.removeObject(forKey: ScreenTimeLabConstants.sessionStartKey)
        defaults?.removeObject(forKey: ScreenTimeLabConstants.sessionEndKey)
    }

    private func applyPersistedSelection() {
        guard let data = defaults?.data(forKey: ScreenTimeLabConstants.selectionKey),
              let selection = try? PropertyListDecoder().decode(FamilyActivitySelection.self, from: data) else {
            return
        }
        store.shield.applications = selection.applicationTokens.isEmpty
            ? nil
            : selection.applicationTokens
        store.shield.webDomains = selection.webDomainTokens.isEmpty
            ? nil
            : selection.webDomainTokens
        store.shield.applicationCategories = selection.categoryTokens.isEmpty
            ? nil
            : .specific(selection.categoryTokens)
    }
}
