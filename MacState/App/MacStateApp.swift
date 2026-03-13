import SwiftUI
import AppKit

@main
struct MacStateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBarController = StatusBarController(manager: MonitorManager.shared)

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleOpenTerminal(_:)),
            name: Notification.Name("com.snail007.macstate.openTerminal"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    @objc private func handleOpenTerminal(_ notification: Notification) {
        guard let directory = notification.object as? String, !directory.isEmpty else { return }
        openTerminal(at: directory)
    }

    private func openTerminal(at directory: String) {
        do {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            proc.arguments = ["-a", "Terminal", directory]
            try proc.run()
        } catch {
            NSLog("MacState: open terminal failed: %@", error.localizedDescription)
        }
    }
}
