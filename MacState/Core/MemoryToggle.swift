import Foundation

@MainActor
final class MemoryToggle: ObservableObject {
    static let shared = MemoryToggle()
    static let changedNotification = Notification.Name("MacStateMemoryToggleChanged")

    private let defaultsKey = "module_enabled_memory"

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
            name: MemoryToggle.changedNotification,
            object: nil,
            userInfo: ["enabled": value]
        )
    }
}
