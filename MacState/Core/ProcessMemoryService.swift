import Foundation
import AppKit

struct ProcessMemoryUsage {
    let pid: Int32
    let name: String
    let icon: NSImage?
    let memoryBytes: UInt64
    let command: String

    var memoryFormatted: String {
        let mb = Double(memoryBytes) / 1_048_576
        if mb < 1 { return "\(memoryBytes / 1024) KB" }
        let gb = mb / 1024
        if gb < 1 { return String(format: "%.1f MB", mb) }
        return String(format: "%.2f GB", gb)
    }
}

final class ProcessMemoryService {
    static let shared = ProcessMemoryService()

    private init() {}

    func topProcesses(limit: Int = 10) -> [ProcessMemoryUsage] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid,rss,args"]

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

        var lightweight: [(pid: Int32, rssKB: UInt64, comm: String)] = []
        let lines = output.components(separatedBy: "\n")

        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 3 else { continue }

            guard let pid = Int32(parts[0]) else { continue }
            guard let rssKB = UInt64(parts[1]) else { continue }
            guard rssKB > 0 else { continue }

            lightweight.append((pid: pid, rssKB: rssKB, comm: String(parts[2])))
        }

        lightweight.sort { $0.rssKB > $1.rssKB }
        let topEntries = lightweight.prefix(limit)

        var results: [ProcessMemoryUsage] = []
        for entry in topEntries {
            let memoryBytes = entry.rssKB * 1024
            let resolved = resolveProcess(pid: entry.pid, fallback: entry.comm)
            results.append(ProcessMemoryUsage(
                pid: entry.pid,
                name: resolved.name,
                icon: resolved.icon,
                memoryBytes: memoryBytes,
                command: entry.comm
            ))
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
