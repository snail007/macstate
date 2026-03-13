import Foundation
import Darwin

final class CPUService {
    static let shared = CPUService()

    private var previousTicks: [(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)] = []

    private init() {
        _ = snapshot()
    }

    func coreCount() -> Int {
        return Int(ProcessInfo.processInfo.activeProcessorCount)
    }

    func totalUsage() -> Double {
        let cores = snapshot()
        guard !cores.isEmpty, cores.count == previousTicks.count else {
            previousTicks = cores
            return 0
        }

        var totalUser: UInt64 = 0
        var totalSystem: UInt64 = 0
        var totalIdle: UInt64 = 0

        for i in 0..<cores.count {
            let dUser = cores[i].user &- previousTicks[i].user
            let dSystem = cores[i].system &- previousTicks[i].system
            let dIdle = cores[i].idle &- previousTicks[i].idle
            totalUser += dUser
            totalSystem += dSystem
            totalIdle += dIdle
        }

        previousTicks = cores
        let total = totalUser + totalSystem + totalIdle
        guard total > 0 else { return 0 }
        return Double(totalUser + totalSystem) / Double(total) * 100.0
    }

    func perCoreUsage() -> [Double] {
        let cores = snapshot()
        guard !cores.isEmpty, cores.count == previousTicks.count else {
            previousTicks = cores
            return Array(repeating: 0, count: cores.count)
        }

        var result = [Double]()
        for i in 0..<cores.count {
            let dUser = cores[i].user &- previousTicks[i].user
            let dSystem = cores[i].system &- previousTicks[i].system
            let dIdle = cores[i].idle &- previousTicks[i].idle
            let total = dUser + dSystem + dIdle
            if total > 0 {
                result.append(Double(dUser + dSystem) / Double(total) * 100.0)
            } else {
                result.append(0)
            }
        }

        previousTicks = cores
        return result
    }

    private func snapshot() -> [(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)] {
        var processorCount: natural_t = 0
        var processorInfo: processor_info_array_t?
        var processorInfoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &processorCount,
            &processorInfo,
            &processorInfoCount
        )

        guard result == KERN_SUCCESS, let info = processorInfo else { return [] }

        var cores: [(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)] = []
        let cpuLoadSize = Int(CPU_STATE_MAX)

        for i in 0..<Int(processorCount) {
            let offset = i * cpuLoadSize
            let user = UInt64(info[offset + Int(CPU_STATE_USER)])
            let system = UInt64(info[offset + Int(CPU_STATE_SYSTEM)])
            let idle = UInt64(info[offset + Int(CPU_STATE_IDLE)])
            let nice = UInt64(info[offset + Int(CPU_STATE_NICE)])
            cores.append((user: user + nice, system: system, idle: idle, nice: nice))
        }

        let size = vm_size_t(processorInfoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: processorInfo), size)

        return cores
    }
}
