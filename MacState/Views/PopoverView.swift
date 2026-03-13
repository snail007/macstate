import SwiftUI

struct PopoverView: View {
    let manager: MonitorManager

    var body: some View {
        SettingsView(manager: manager)
    }
}
