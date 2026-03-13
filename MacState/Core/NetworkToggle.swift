import Foundation

@MainActor
final class NetworkToggle: ObservableObject {
    static let shared = NetworkToggle()
    static let changedNotification = Notification.Name("MacStateNetworkToggleChanged")

    private let defaultsKey = "module_enabled_network"

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
            name: NetworkToggle.changedNotification,
            object: nil,
            userInfo: ["enabled": value]
        )
    }
}
