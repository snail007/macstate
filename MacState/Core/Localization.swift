import Foundation
import Combine

enum Language: String, CaseIterable {
    case zh = "zh"
    case en = "en"

    var displayName: String {
        switch self {
        case .zh: return "中文"
        case .en: return "English"
        }
    }
}

@MainActor
final class L10n: ObservableObject {
    static let shared = L10n()

    @Published var language: Language = .zh {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: "app_language")
        }
    }

    private init() {
        if let saved = UserDefaults.standard.string(forKey: "app_language"),
           let lang = Language(rawValue: saved) {
            language = lang
        }
    }

    // MARK: - 通用
    var appName: String { "MacState" }
    var back: String { language == .zh ? "返回" : "Back" }
    var settings: String { language == .zh ? "设置" : "Settings" }
    var quit: String { language == .zh ? "退出 MacState" : "Quit MacState" }

    // MARK: - 模块名称
    var modules: String { language == .zh ? "模块" : "Modules" }

    func moduleName(_ type: ModuleType) -> String {
        switch type {
        case .cpuUsage:
            return language == .zh ? "CPU 使用率" : "CPU Usage"
        case .cpuTemp:
            return language == .zh ? "CPU 温度" : "CPU Temperature"
        case .memory:
            return language == .zh ? "内存" : "Memory"
        case .fan:
            return language == .zh ? "风扇转速" : "Fan Speed"
        case .network:
            return language == .zh ? "网络速度" : "Network Speed"
        case .battery:
            return language == .zh ? "充电功率" : "Charging Power"
        }
    }

    // MARK: - 弹出面板
    var cpu: String { "CPU" }
    var temperature: String { language == .zh ? "温度" : "Temperature" }
    var memory: String { language == .zh ? "内存" : "Memory" }

    func fanLabel(_ index: Int) -> String {
        language == .zh ? "风扇 \(index)" : "Fan \(index)"
    }

    // MARK: - 网络
    var upload: String { language == .zh ? "上传" : "Upload" }
    var download: String { language == .zh ? "下载" : "Download" }

    // MARK: - 电池卡片
    var batteryPower: String { language == .zh ? "电池功率" : "Battery Power" }
    var chargingPrefix: String { language == .zh ? "充电" : "Charging" }
    var dischargingPrefix: String { language == .zh ? "放电" : "Discharging" }
    var charger: String { language == .zh ? "充电器" : "Charger" }
    var chargerPower: String { language == .zh ? "充电功率" : "Charging Power" }
    var adapterPower: String { language == .zh ? "充电功率" : "Charging Power" }
    var ratedPower: String { language == .zh ? "协商功率" : "Negotiated" }
    var voltageLabel: String { language == .zh ? "电池电压" : "Battery Voltage" }
    var currentLabel: String { language == .zh ? "电池电流" : "Battery Current" }
    var batteryLevel: String { language == .zh ? "电池电量" : "Battery Level" }
    var cycleCountLabel: String { language == .zh ? "电池循环" : "Battery Cycles" }
    var batteryHealth: String { language == .zh ? "电池健康" : "Battery Health" }

    // MARK: - 进程面板
    var topProcesses: String { language == .zh ? "进程排行" : "Top Processes" }
    var processName: String { language == .zh ? "进程" : "Process" }
    var noActiveProcess: String { language == .zh ? "暂无活跃进程" : "No active processes" }
    var commandLine: String { language == .zh ? "命令行" : "Command" }
    var viewButton: String { language == .zh ? "查看" : "View" }
    var geoLocation: String { language == .zh ? "归属地" : "Location" }

    // MARK: - 设置面板
    var refreshInterval: String { language == .zh ? "刷新间隔" : "Refresh Interval" }
    var general: String { language == .zh ? "通用" : "General" }
    var launchAtLogin: String { language == .zh ? "开机自启动" : "Launch at Login" }
    var languageLabel: String { language == .zh ? "语言" : "Language" }
    var finderMenu: String { language == .zh ? "Finder 右键菜单" : "Finder Context Menu" }
}
