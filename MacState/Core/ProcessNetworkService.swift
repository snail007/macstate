import Foundation
import AppKit

struct ProcessNetworkUsage {
    let pid: Int32
    let name: String
    let icon: NSImage?
    let uploadBytesPerSec: Int64
    let downloadBytesPerSec: Int64
    let command: String
    var totalBytesPerSec: Int64 { uploadBytesPerSec + downloadBytesPerSec }
}

final class ProcessNetworkService {
    static let shared = ProcessNetworkService()

    private var previousSamples: [String: (download: Int64, upload: Int64)] = [:]
    private var previousTimestamp: TimeInterval = 0

    private init() {
        previousSamples = runNettop()
        previousTimestamp = ProcessInfo.processInfo.systemUptime
    }

    func topProcesses(limit: Int = 10) -> [ProcessNetworkUsage] {
        let result = computeTop(limit: limit)
        if !result.isEmpty { return result }
        Thread.sleep(forTimeInterval: 1.0)
        return computeTop(limit: limit)
    }

    private func computeTop(limit: Int) -> [ProcessNetworkUsage] {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - previousTimestamp
        guard elapsed > 0.5 else { return [] }

        let currentSamples = runNettop()
        defer {
            previousSamples = currentSamples
            previousTimestamp = now
        }

        guard !previousSamples.isEmpty else { return [] }

        var pidAggregated: [Int32: (name: String, download: Int64, upload: Int64)] = [:]

        for (key, current) in currentSamples {
            guard let previous = previousSamples[key] else { continue }
            let dDown = current.download - previous.download
            let dUp = current.upload - previous.upload
            guard dDown >= 0, dUp >= 0, (dDown + dUp) > 0 else { continue }

            let downPerSec = Int64(Double(dDown) / elapsed)
            let upPerSec = Int64(Double(dUp) / elapsed)

            let parts = key.split(separator: ".")
            guard let pidStr = parts.last, let pid = Int32(pidStr) else { continue }
            let processName = parts.dropLast().joined(separator: ".")

            if var existing = pidAggregated[pid] {
                existing.download += downPerSec
                existing.upload += upPerSec
                pidAggregated[pid] = existing
            } else {
                pidAggregated[pid] = (name: processName, download: downPerSec, upload: upPerSec)
            }
        }

        var sorted = Array(pidAggregated)
        sorted.sort { $0.value.download + $0.value.upload > $1.value.download + $1.value.upload }
        let topEntries = sorted.prefix(limit)

        var results: [ProcessNetworkUsage] = []
        for (pid, info) in topEntries {
            let resolved = resolveProcess(pid: pid, fallback: info.name)
            let command = resolveCommand(pid: pid)
            results.append(ProcessNetworkUsage(
                pid: pid,
                name: resolved.name,
                icon: resolved.icon,
                uploadBytesPerSec: info.upload,
                downloadBytesPerSec: info.download,
                command: command
            ))
        }

        return results
    }

    private func runNettop() -> [String: (download: Int64, upload: Int64)] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        task.arguments = [
            "-P", "-L", "1", "-n",
            "-k",
            "time,interface,state,rx_dupe,rx_ooo,re-tx,rtt_avg,rcvsize,tx_win,tc_class,tc_mgt,cc_algo,P,C,R,W,arch"
        ]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            return [:]
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return [:] }

        var samples: [String: (download: Int64, upload: Int64)] = [:]
        let lines = output.components(separatedBy: "\n")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("time") else { continue }
            let columns = trimmed.components(separatedBy: ",")
            guard columns.count >= 3 else { continue }

            let processKey = columns[0].trimmingCharacters(in: .whitespaces)
            guard !processKey.isEmpty, processKey != "time" else { continue }

            guard let download = Int64(columns[1].trimmingCharacters(in: .whitespaces)),
                  let upload = Int64(columns[2].trimmingCharacters(in: .whitespaces)) else { continue }

            if var existing = samples[processKey] {
                existing.download += download
                existing.upload += upload
                samples[processKey] = existing
            } else {
                samples[processKey] = (download: download, upload: upload)
            }
        }

        return samples
    }

    private func resolveProcess(pid: Int32, fallback: String) -> (name: String, icon: NSImage?) {
        let app = NSRunningApplication(processIdentifier: pid)
        let icon = app?.icon

        if let localizedName = app?.localizedName, !localizedName.isEmpty {
            return (name: localizedName, icon: icon)
        }

        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let ret = proc_pidpath(pid, &pathBuffer, UInt32(MAXPATHLEN))
        if ret > 0 {
            let fullPath = String(cString: pathBuffer)
            let shortName = (fullPath as NSString).lastPathComponent
            if !shortName.isEmpty {
                return (name: shortName, icon: icon)
            }
        }

        return (name: fallback, icon: icon)
    }

    private func resolveCommand(pid: Int32) -> String {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: Int = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else {
            return processPath(pid: pid)
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else {
            return processPath(pid: pid)
        }
        guard size > MemoryLayout<Int32>.size else { return processPath(pid: pid) }
        let argc = buffer.withUnsafeBufferPointer { buf -> Int32 in
            buf.baseAddress!.withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }
        }
        var offset = MemoryLayout<Int32>.size
        // skip exec_path
        while offset < size && buffer[offset] != 0 { offset += 1 }
        // skip trailing nulls
        while offset < size && buffer[offset] == 0 { offset += 1 }
        // read argc args
        var args: [String] = []
        var count: Int32 = 0
        while offset < size && count < argc {
            var arg = ""
            while offset < size && buffer[offset] != 0 {
                arg.append(Character(UnicodeScalar(buffer[offset])))
                offset += 1
            }
            args.append(arg)
            count += 1
            offset += 1
        }
        return args.isEmpty ? processPath(pid: pid) : args.joined(separator: " ")
    }

    private func processPath(pid: Int32) -> String {
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let ret = proc_pidpath(pid, &pathBuffer, UInt32(MAXPATHLEN))
        if ret > 0 {
            return String(cString: pathBuffer)
        }
        return ""
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let absBytes = abs(bytes)
        let kb = Double(absBytes) / 1024
        if kb < 1 { return "\(absBytes) B/s" }
        let mb = kb / 1024
        if mb < 1 { return String(format: "%.1f KB/s", kb) }
        let gb = mb / 1024
        if gb < 1 { return String(format: "%.1f MB/s", mb) }
        return String(format: "%.2f GB/s", gb)
    }
}
