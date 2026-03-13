import Foundation

@MainActor
final class FinderMenuToggle: ObservableObject {
    static let shared = FinderMenuToggle()
    static let changedNotification = Notification.Name("MacStateFinderMenuToggleChanged")

    private let defaultsKey = "module_enabled_finder_menu"

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
            name: FinderMenuToggle.changedNotification,
            object: nil,
            userInfo: ["enabled": value]
        )
        let action = value ? "use" : "ignore"
        let task = Process()
        task.launchPath = "/usr/bin/pluginkit"
        task.arguments = ["-e", action, "-i", "com.snail007.macstate.FinderMenu"]
        try? task.run()
    }
}
