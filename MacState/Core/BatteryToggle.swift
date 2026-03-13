import Foundation

@MainActor
final class BatteryToggle: ObservableObject {
    static let shared = BatteryToggle()
    static let changedNotification = Notification.Name("MacStateBatteryToggleChanged")

    private let defaultsKey = "module_enabled_battery"

    @Published var enabled: Bool

    private init() {
        if UserDefaults.standard.object(forKey: defaultsKey) == nil {
            enabled = true
        } else {
            enabled = UserDefaults.standard.bool(forKey: defaultsKey)
        }
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        UserDefaults.standard.set(value, forKey: defaultsKey)
        NotificationCenter.default.post(
            name: BatteryToggle.changedNotification,
            object: nil,
            userInfo: ["enabled": value]
        )
    }
}
