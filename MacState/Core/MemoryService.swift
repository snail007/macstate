import Foundation
import Darwin

enum MemoryPressure {
    case nominal
    case warning
    case critical
}

struct MemoryUsage {
    let total: UInt64
    let used: UInt64
    let free: UInt64
    let active: UInt64
    let inactive: UInt64
    let wired: UInt64
    let compressed: UInt64

    var usedPercentage: Double {
        guard total > 0 else { return 0 }
        return Double(used) / Double(total) * 100.0
    }

    var pressureLevel: MemoryPressure {
        let pct = usedPercentage
        if pct > 90 { return .critical }
        if pct > 80 { return .warning }
        return .nominal
    }
}

final class MemoryService {
    static let shared = MemoryService()
    private init() {}

    func usage() -> MemoryUsage {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )

        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        let total = ProcessInfo.processInfo.physicalMemory
        guard result == KERN_SUCCESS else {
            return MemoryUsage(total: total, used: 0, free: total,
                               active: 0, inactive: 0, wired: 0, compressed: 0)
        }

        let pageSize = UInt64(vm_kernel_page_size)
        let active = UInt64(stats.active_count) * pageSize
        let inactive = UInt64(stats.inactive_count) * pageSize
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        let used = active + wired + compressed
        let free = total > used ? total - used : 0

        return MemoryUsage(
            total: total, used: used, free: free,
            active: active, inactive: inactive,
            wired: wired, compressed: compressed
        )
    }
}
