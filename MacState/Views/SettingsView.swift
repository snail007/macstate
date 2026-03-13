import SwiftUI

struct SettingsView: View {
    @ObservedObject var l10n: L10n = L10n.shared
    @StateObject private var loginService = LaunchAtLoginService.shared
    @ObservedObject private var cpuTempToggle = CpuTempToggle.shared
    @ObservedObject private var memoryToggle = MemoryToggle.shared
    @ObservedObject private var fanToggle = FanToggle.shared
    @ObservedObject private var networkToggle = NetworkToggle.shared
    @ObservedObject private var batteryToggle = BatteryToggle.shared
    @ObservedObject private var finderMenuToggle = FinderMenuToggle.shared

    let manager: MonitorManager

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(l10n.appName)
                    .font(.headline)
                Spacer()
                Button(action: {
                    if let url = URL(string: "https://github.com/snail007/macstate") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "link")
                        Text("GitHub")
                    }
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
                }
                .buttonStyle(.plain)
            }

            Divider()

            Text(l10n.modules)
                .font(.subheadline.bold())
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                Image(systemName: "thermometer.medium")
                    .frame(width: 20, alignment: .center)
                Text(l10n.moduleName(.cpuTemp))
                    .frame(maxWidth: .infinity, alignment: .leading)
                AppKitSwitch(label: "cpuTemp", isOn: cpuTempToggle.enabled) { newValue in
                    CpuTempToggle.shared.setEnabled(newValue)
                }
                .frame(width: 38, height: 22)
            }

            HStack(spacing: 8) {
                Image(systemName: "memorychip")
                    .frame(width: 20, alignment: .center)
                Text(l10n.moduleName(.memory))
                    .frame(maxWidth: .infinity, alignment: .leading)
                AppKitSwitch(label: "memory", isOn: memoryToggle.enabled) { newValue in
                    MemoryToggle.shared.setEnabled(newValue)
                }
                .frame(width: 38, height: 22)
            }

            HStack(spacing: 8) {
                Image(systemName: "fan")
                    .frame(width: 20, alignment: .center)
                Text(l10n.moduleName(.fan))
                    .frame(maxWidth: .infinity, alignment: .leading)
                AppKitSwitch(label: "fan", isOn: fanToggle.enabled) { newValue in
                    FanToggle.shared.setEnabled(newValue)
                }
                .frame(width: 38, height: 22)
            }

            HStack(spacing: 8) {
                Image(systemName: "network")
                    .frame(width: 20, alignment: .center)
                Text(l10n.moduleName(.network))
                    .frame(maxWidth: .infinity, alignment: .leading)
                AppKitSwitch(label: "network", isOn: networkToggle.enabled) { newValue in
                    NetworkToggle.shared.setEnabled(newValue)
                }
                .frame(width: 38, height: 22)
            }

            if BatteryService.hasBattery {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.fill")
                        .frame(width: 20, alignment: .center)
                    Text(l10n.moduleName(.battery))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    AppKitSwitch(label: "battery", isOn: batteryToggle.enabled) { newValue in
                        BatteryToggle.shared.setEnabled(newValue)
                    }
                    .frame(width: 38, height: 22)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "contextualmenu.and.cursorarrow")
                    .frame(width: 20, alignment: .center)
                Text(l10n.finderMenu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                AppKitSwitch(label: "finderMenu", isOn: finderMenuToggle.enabled) { newValue in
                    FinderMenuToggle.shared.setEnabled(newValue)
                }
                .frame(width: 38, height: 22)
            }

            Divider()

            HStack {
                Text(l10n.refreshInterval)
                    .font(.subheadline.bold())
                    .foregroundColor(.secondary)
                Spacer()
                Picker("", selection: Binding(
                    get: { manager.refreshInterval },
                    set: { manager.updateRefreshInterval($0) }
                )) {
                    Text("3s").tag(3.0 as TimeInterval)
                    Text("5s").tag(5.0 as TimeInterval)
                    Text("10s").tag(10.0 as TimeInterval)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
            }

            Divider()

            Text(l10n.general)
                .font(.subheadline.bold())
                .foregroundColor(.secondary)

            Toggle(isOn: Binding(
                get: { loginService.isEnabled },
                set: { _ in loginService.toggle() }
            )) {
                HStack(spacing: 8) {
                    Image(systemName: "power")
                        .frame(width: 20, alignment: .center)
                    Text(l10n.launchAtLogin)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .frame(width: 20, alignment: .center)
                Text(l10n.languageLabel)
                Spacer()
                Picker("", selection: $l10n.language) {
                    ForEach(Language.allCases, id: \.rawValue) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
            }

            Divider()

            Button(l10n.quit) {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundColor(.red)
        }
        .padding(20)
        .frame(width: 280)
    }
}
