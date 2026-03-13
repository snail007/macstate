import Cocoa
import FinderSync

class FinderMenuSync: FIFinderSync {

    private let enabledKey = "module_enabled_finder_menu"

    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = Set([URL(fileURLWithPath: "/")])
        NSLog("FinderMenuSync launched from %@", Bundle.main.bundlePath as NSString)
    }

    // MARK: - Context Menu

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = NSMenu(title: "")

        let defaults = UserDefaults.standard
        guard defaults.object(forKey: enabledKey) == nil || defaults.bool(forKey: enabledKey) else {
            return menu
        }

        let openTerminal = NSMenuItem(
            title: "在此打开终端",
            action: #selector(openTerminalHere(_:)),
            keyEquivalent: ""
        )
        openTerminal.image = NSImage(named: NSImage.networkName)

        let copyPath = NSMenuItem(
            title: "复制路径",
            action: #selector(copyPathToClipboard(_:)),
            keyEquivalent: ""
        )
        copyPath.image = NSImage(named: NSImage.pathTemplateName)

        menu.addItem(openTerminal)
        menu.addItem(copyPath)

        return menu
    }

    // MARK: - Actions

    @objc func openTerminalHere(_ sender: AnyObject?) {
        guard let target = targetDirectory() else { return }
        DistributedNotificationCenter.default().post(
            name: Notification.Name("com.snail007.macstate.openTerminal"),
            object: target
        )
    }

    @objc func copyPathToClipboard(_ sender: AnyObject?) {
        var paths: [String] = []

        if let items = FIFinderSyncController.default().selectedItemURLs(), !items.isEmpty {
            paths = items.map { $0.path }
        } else if let target = FIFinderSyncController.default().targetedURL() {
            paths = [target.path]
        }

        guard !paths.isEmpty else { return }

        let board = NSPasteboard.general
        board.clearContents()
        board.setString(paths.joined(separator: "\n"), forType: .string)
    }

    // MARK: - Helpers

    private func targetDirectory() -> String? {
        if let items = FIFinderSyncController.default().selectedItemURLs(), items.count == 1 {
            let url = items[0]
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                return isDir.boolValue ? url.path : url.deletingLastPathComponent().path
            }
        }
        return FIFinderSyncController.default().targetedURL()?.path
    }
}
