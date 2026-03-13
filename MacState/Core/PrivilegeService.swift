import Foundation
import Security
import AppKit

final class PrivilegeService {
    static let shared = PrivilegeService()

    var isRunningAsRoot: Bool {
        getuid() == 0
    }

    var isInAdminGroup: Bool {
        let groups = UnsafeMutablePointer<gid_t>.allocate(capacity: 64)
        defer { groups.deallocate() }
        var ngroups: Int32 = 64
        let username = NSUserName()
        getgrouplist(username, Int32(getgid()), groups, &ngroups)

        let adminGID: gid_t = 80
        for i in 0..<Int(ngroups) {
            if groups[i] == adminGID { return true }
        }
        return false
    }

    func requestAdminPrivileges(reason: String) -> Bool {
        var authRef: AuthorizationRef?
        var flags = AuthorizationFlags()
        flags.insert(.interactionAllowed)
        flags.insert(.preAuthorize)
        flags.insert(.extendRights)

        let rightName = "com.snail007.macstate.admin"
        var item = AuthorizationItem(
            name: (rightName as NSString).utf8String!,
            valueLength: 0,
            value: nil,
            flags: 0
        )

        var rights = withUnsafeMutablePointer(to: &item) { ptr in
            AuthorizationRights(count: 1, items: ptr)
        }

        let status = AuthorizationCreate(&rights, nil, flags, &authRef)
        if let ref = authRef {
            AuthorizationFree(ref, [])
        }
        return status == errAuthorizationSuccess
    }

    func relaunchWithElevation() {
        guard let bundlePath = Bundle.main.executablePath else { return }

        let script = """
        do shell script "'\(bundlePath)' &" with administrator privileges
        """

        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if error == nil {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private init() {}
}
