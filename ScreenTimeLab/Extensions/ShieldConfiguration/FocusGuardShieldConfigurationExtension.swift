import ManagedSettings
import ManagedSettingsUI
import UIKit

final class FocusGuardShieldConfigurationExtension: ShieldConfigurationDataSource {
    override func configuration(shielding application: Application) -> ShieldConfiguration {
        configuration()
    }

    override func configuration(shielding application: Application, in category: ActivityCategory) -> ShieldConfiguration {
        configuration()
    }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        configuration()
    }

    override func configuration(shielding webDomain: WebDomain, in category: ActivityCategory) -> ShieldConfiguration {
        configuration()
    }

    private func configuration() -> ShieldConfiguration {
        ShieldConfiguration(
            backgroundBlurStyle: .systemMaterialDark,
            backgroundColor: .systemIndigo,
            icon: UIImage(systemName: "moon.zzz.fill"),
            title: .init(text: "FocusGuard", color: .white),
            subtitle: .init(text: "This is a focus session. Return when the timer ends.", color: .white),
            primaryButtonLabel: .init(text: "Close", color: .white),
            primaryButtonBackgroundColor: .white,
            secondaryButtonLabel: nil)
    }
}
