import Foundation
import Combine

protocol MonitorModule: AnyObject, Identifiable {
    var id: String { get }
    var name: String { get }
    var icon: String { get }
    var isEnabled: Bool { get set }
    var isAvailable: Bool { get }

    func refresh()
}

enum ModuleType: String, CaseIterable, Identifiable {
    case cpuUsage = "cpu_usage"
    case cpuTemp = "cpu_temp"
    case memory = "memory"
    case fan = "fan"
    case network = "network"
    case battery = "battery"

    var id: String { rawValue }

    var defaultsKey: String {
        return "module_enabled_\(rawValue)"
    }
}

@MainActor
final class MonitorManager: ObservableObject {
    static let shared = MonitorManager()

    @Published var cpuUsage: Double = 0
    @Published var cpuTemp: Double = 0
    @Published var memoryUsage: MemoryUsage = MemoryUsage(
        total: 0, used: 0, free: 0, active: 0, inactive: 0, wired: 0, compressed: 0
    )
    @Published var fanSpeeds: [(current: Double, min: Double, max: Double)] = []
    @Published var networkSpeed = NetworkSpeed(upload: 0, download: 0)
    @Published var batteryInfo = BatteryInfo()

    @Published var refreshInterval: TimeInterval = 3.0

    private var timer: Timer?
    private let defaults = UserDefaults.standard
    private let intervalKey = "refreshInterval"

    private init() {
        migrateOldSettings()
        loadInterval()
        startMonitoring()
    }

    // MARK: - Refresh Interval

    func updateRefreshInterval(_ interval: TimeInterval) {
        refreshInterval = max(1.0, min(30.0, interval))
        defaults.set(refreshInterval, forKey: intervalKey)
        startMonitoring()
    }

    // MARK: - Monitoring

    func startMonitoring() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        refresh()
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    private let workQueue = DispatchQueue(label: "com.snail007.macstate.monitor", qos: .utility)

    private func refresh() {
        let cpuTempEnabled = CpuTempToggle.shared.enabled
        let memoryEnabled = MemoryToggle.shared.enabled
        let fanEnabled = FanToggle.shared.enabled
        let networkEnabled = NetworkToggle.shared.enabled
        let batteryEnabled = BatteryToggle.shared.enabled

        workQueue.async { [weak self] in
            let cpu = CPUService.shared.totalUsage()
            let temp = cpuTempEnabled ? SMCService.shared.cpuTemperature() ?? 0 : 0
            let mem = memoryEnabled ? MemoryService.shared.usage() : nil
            let fans = fanEnabled ? SMCService.shared.allFanSpeeds() : nil
            let net = networkEnabled ? NetworkService.shared.currentSpeed() : nil
            let bat = batteryEnabled ? BatteryService.shared.info() : nil

            DispatchQueue.main.async {
                guard let self else { return }
                if Int(self.cpuUsage) != Int(cpu) { self.cpuUsage = cpu }
                if cpuTempEnabled && Int(self.cpuTemp) != Int(temp) { self.cpuTemp = temp }
                if let mem, Int(self.memoryUsage.usedPercentage) != Int(mem.usedPercentage) { self.memoryUsage = mem }
                if let fans {
                    if fans.count != self.fanSpeeds.count || !zip(fans, self.fanSpeeds).allSatisfy({ Int($0.0.current) == Int($0.1.current) }) {
                        self.fanSpeeds = fans
                    }
                }
                if let net {
                    if Int(net.upload) != Int(self.networkSpeed.upload) || Int(net.download) != Int(self.networkSpeed.download) {
                        self.networkSpeed = net
                    }
                }
                if let bat {
                    if bat.percentage != self.batteryInfo.percentage ||
                       bat.isCharging != self.batteryInfo.isCharging ||
                       bat.isPluggedIn != self.batteryInfo.isPluggedIn ||
                       Int(bat.adapterPowerWatts * 10) != Int(self.batteryInfo.adapterPowerWatts * 10) ||
                       Int(bat.powerWatts * 10) != Int(self.batteryInfo.powerWatts * 10) {
                        self.batteryInfo = bat
                    }
                }
            }
        }
    }

    // MARK: - Settings

    private func loadInterval() {
        let interval = defaults.double(forKey: intervalKey)
        if interval > 0 {
            refreshInterval = interval
        }
    }

    private func migrateOldSettings() {
        let oldKey = "enabledModules"
        let versionKey = "settingsVersion"
        let currentVersion = 2

        if defaults.integer(forKey: versionKey) < currentVersion {
            if let saved = defaults.array(forKey: oldKey) as? [String] {
                for moduleType in ModuleType.allCases {
                    if moduleType == .cpuUsage { continue }
                    defaults.set(saved.contains(moduleType.rawValue), forKey: moduleType.defaultsKey)
                }
                defaults.removeObject(forKey: oldKey)
            }

            let allKeys = defaults.dictionaryRepresentation().keys
            for key in allKeys {
                if key.hasPrefix("NSStatusItem") {
                    defaults.removeObject(forKey: key)
                }
            }

            defaults.set(currentVersion, forKey: versionKey)
        }
    }
}
