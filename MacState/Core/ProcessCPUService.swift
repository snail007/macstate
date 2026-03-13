import Foundation
import AppKit

struct ProcessCPUUsage {
    let pid: Int32
    let name: String
    let icon: NSImage?
    let cpuPercent: Double
    let command: String
}

final class ProcessCPUService {
    static let shared = ProcessCPUService()

    private init() {}

    func topProcesses(limit: Int = 10) -> [ProcessCPUUsage] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axro", "pid,pcpu,args"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var results: [ProcessCPUUsage] = []
        let lines = output.components(separatedBy: "\n")

        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 3 else { continue }

            guard let pid = Int32(parts[0]) else { continue }
            guard let cpu = Double(parts[1]) else { continue }
            guard cpu > 0 else { continue }

            let comm = String(parts[2])
            let resolved = resolveProcess(pid: pid, fallback: comm)

            results.append(ProcessCPUUsage(
                pid: pid,
                name: resolved.name,
                icon: resolved.icon,
                cpuPercent: cpu,
                command: comm
            ))

            if results.count >= limit { break }
        }

        return results
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
            let lastComponent = (fullPath as NSString).lastPathComponent
            if !lastComponent.isEmpty {
                return (name: lastComponent, icon: icon)
            }
        }

        return (name: fallback, icon: icon)
    }
}
