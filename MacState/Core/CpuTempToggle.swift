import Foundation

@MainActor
final class CpuTempToggle: ObservableObject {
    static let shared = CpuTempToggle()
    static let changedNotification = Notification.Name("MacStateCpuTempToggleChanged")

    private let defaultsKey = "module_enabled_cpu_temp"

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
            name: CpuTempToggle.changedNotification,
            object: nil,
            userInfo: ["enabled": value]
        )
    }
}
