import Foundation
import IOKit
import IOKit.ps

struct BatteryInfo {
    var isAvailable: Bool = false
    var isCharging: Bool = false
    var isPluggedIn: Bool = false
    var voltage: Int = 0            // mV
    var amperage: Int = 0           // mA, positive=charging, negative=discharging
    var currentCapacity: Int = 0    // mAh
    var maxCapacity: Int = 0        // mAh
    var designCapacity: Int = 0     // mAh
    var cycleCount: Int = 0
    var uiPercentage: Int = -1       // UISoc from BatteryData, -1 = not available
    var adapterWatts: Int = 0
    var adapterName: String = ""
    var chargingCurrent: Int = 0    // mA
    var chargingVoltage: Int = 0    // mV
    var adapterPowerWatts: Double = 0  // SMC PDTR — real-time adapter power

    var percentage: Int {
        if uiPercentage >= 0 { return uiPercentage }
        guard maxCapacity > 0 else { return 0 }
        return min(100, currentCapacity * 100 / maxCapacity)
    }

    var healthPercentage: Int {
        guard designCapacity > 0 else { return 0 }
        return min(100, maxCapacity * 100 / designCapacity)
    }

    // watts = voltage(mV) * amperage(mA) / 1_000_000
    var powerWatts: Double {
        return Double(voltage) * Double(amperage) / 1_000_000.0
    }
}

final class BatteryService {
    static let shared = BatteryService()

    private init() {}

    private func powerSourceDescription() -> [String: Any]? {
        let psInfo = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let psList = IOPSCopyPowerSourcesList(psInfo).takeRetainedValue() as [CFTypeRef]
        for ps in psList {
            guard let desc = IOPSGetPowerSourceDescription(psInfo, ps)?.takeUnretainedValue() as? [String: Any],
                  let type = desc[kIOPSTypeKey] as? String,
                  type == kIOPSInternalBatteryType else {
                continue
            }
            return desc
        }
        return nil
    }

    static var hasBattery: Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            IOObjectRelease(service)
            return true
        }
        return shared.powerSourceDescription() != nil
    }

    func info() -> BatteryInfo {
        var result = BatteryInfo()
        let psDesc = powerSourceDescription()

        if let psDesc {
            result.isAvailable = true
            if let state = psDesc[kIOPSPowerSourceStateKey] as? String {
                result.isPluggedIn = (state == kIOPSACPowerValue)
            }
            if let charging = psDesc[kIOPSIsChargingKey] as? Bool {
                result.isCharging = charging
            }
            if let cap = psDesc[kIOPSCurrentCapacityKey] as? Int {
                result.uiPercentage = cap
            }
            if let current = psDesc["Current"] as? Int {
                result.amperage = current
            }
        }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return result }
        defer { IOObjectRelease(service) }

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return result }

        result.isAvailable = true
        result.isCharging = dict["IsCharging"] as? Bool ?? result.isCharging
        result.isPluggedIn = dict["ExternalConnected"] as? Bool ?? result.isPluggedIn
        result.voltage = dict["Voltage"] as? Int
            ?? dict["AppleRawBatteryVoltage"] as? Int
            ?? result.voltage
        // Prefer AppleRawMaxCapacity/AppleRawCurrentCapacity (always mAh).
        // On older Intel Macs, MaxCapacity/CurrentCapacity return percentage (0-100)
        // instead of mAh, which breaks health calculation.
        result.currentCapacity = dict["AppleRawCurrentCapacity"] as? Int
            ?? dict["CurrentCapacity"] as? Int
            ?? result.currentCapacity
        result.maxCapacity = dict["AppleRawMaxCapacity"] as? Int
            ?? dict["MaxCapacity"] as? Int
            ?? max(result.maxCapacity, 1)
        result.designCapacity = dict["DesignCapacity"] as? Int ?? max(result.designCapacity, 1)
        result.cycleCount = dict["CycleCount"] as? Int ?? result.cycleCount

        if let batteryData = dict["BatteryData"] as? [String: Any],
           let uiSoc = batteryData["UISoc"] as? Int {
            result.uiPercentage = uiSoc
        }

        if let n = dict["InstantAmperage"] as? NSNumber {
            result.amperage = Int(Int16(truncatingIfNeeded: n.int64Value))
        } else if let n = dict["Amperage"] as? NSNumber {
            result.amperage = Int(Int16(truncatingIfNeeded: n.int64Value))
        }

        if let adapterDetails = dict["AdapterDetails"] as? [String: Any] {
            result.adapterWatts = adapterDetails["Watts"] as? Int ?? 0
            result.adapterName = adapterDetails["Name"] as? String ?? ""
        }

        if result.adapterWatts == 0 {
            if let acDetails = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] {
                result.adapterWatts = acDetails[kIOPSPowerAdapterWattsKey] as? Int ?? 0
            }
        }

        if let chargerData = dict["ChargerData"] as? [String: Any] {
            result.chargingCurrent = chargerData["ChargingCurrent"] as? Int ?? 0
            result.chargingVoltage = chargerData["ChargingVoltage"] as? Int ?? 0
        }

        // Some machines report ExternalConnected = No in AppleSmartBattery while IOPS
        // correctly reports AC Power. Prefer the power-source view when it says AC.
        if let state = psDesc?[kIOPSPowerSourceStateKey] as? String, state == kIOPSACPowerValue {
            result.isPluggedIn = true
        }

        // Only read adapter power (PDTR) when actually plugged in.
        // On some Macs PDTR returns a small residual value (~0.01–0.04 W) on battery,
        // which would incorrectly replace powerWatts and cause the display to show "--".
        if result.isPluggedIn, let pdtr = SMCService.shared.readKey("PDTR"), pdtr > 0 {
            result.adapterPowerWatts = pdtr
        }

        return result
    }
}
