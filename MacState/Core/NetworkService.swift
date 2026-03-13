import Foundation
import Darwin

struct NetworkSpeed {
    let upload: UInt64
    let download: UInt64

    var uploadFormatted: String { NetworkService.formatBytes(upload) }
    var downloadFormatted: String { NetworkService.formatBytes(download) }
}

final class NetworkService {
    static let shared = NetworkService()

    private var previousUpload: UInt64 = 0
    private var previousDownload: UInt64 = 0
    private var previousTimestamp: TimeInterval = 0

    private init() {
        let (up, down) = readTotalBytes()
        previousUpload = up
        previousDownload = down
        previousTimestamp = ProcessInfo.processInfo.systemUptime
    }

    func currentSpeed() -> NetworkSpeed {
        let (totalUp, totalDown) = readTotalBytes()
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - previousTimestamp

        guard elapsed > 0 else {
            return NetworkSpeed(upload: 0, download: 0)
        }

        let upSpeed = totalUp > previousUpload
            ? UInt64(Double(totalUp - previousUpload) / elapsed)
            : 0
        let downSpeed = totalDown > previousDownload
            ? UInt64(Double(totalDown - previousDownload) / elapsed)
            : 0

        previousUpload = totalUp
        previousDownload = totalDown
        previousTimestamp = now

        return NetworkSpeed(upload: upSpeed, download: downSpeed)
    }

    func totalBytes() -> (upload: UInt64, download: UInt64) {
        return readTotalBytes()
    }

    static func formatBytes(_ bytes: UInt64) -> String {
        let kb = Double(bytes) / 1024
        if kb < 1 { return "\(bytes) B/s" }
        let mb = kb / 1024
        if mb < 1 { return String(format: "%.1f KB/s", kb) }
        let gb = mb / 1024
        if gb < 1 { return String(format: "%.1f MB/s", mb) }
        return String(format: "%.2f GB/s", gb)
    }

    private func readTotalBytes() -> (upload: UInt64, download: UInt64) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len: size_t = 0

        guard sysctl(&mib, UInt32(mib.count), nil, &len, nil, 0) == 0, len > 0 else {
            return (0, 0)
        }

        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: len)
        defer { buf.deallocate() }

        guard sysctl(&mib, UInt32(mib.count), buf, &len, nil, 0) == 0 else {
            return (0, 0)
        }

        var totalUpload: UInt64 = 0
        var totalDownload: UInt64 = 0
        var next = buf
        let end = buf.advanced(by: len)

        while next < end {
            let ifm = next.withMemoryRebound(to: if_msghdr.self, capacity: 1) { $0.pointee }
            let msgLen = Int(ifm.ifm_msglen)
            guard msgLen > 0 else { break }

            if ifm.ifm_type == UInt8(RTM_IFINFO2) {
                let ifm2 = next.withMemoryRebound(to: if_msghdr2.self, capacity: 1) { $0.pointee }

                let sdlPtr = next.advanced(by: MemoryLayout<if_msghdr2>.size)
                    .withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { $0 }
                let nameLen = Int(sdlPtr.pointee.sdl_nlen)

                if nameLen > 0 {
                    let nameData = Data(
                        bytes: &sdlPtr.pointee.sdl_data,
                        count: nameLen
                    )
                    if let name = String(data: nameData, encoding: .ascii) {
                        if name.hasPrefix("en") {
                            totalDownload += ifm2.ifm_data.ifi_ibytes
                            totalUpload += ifm2.ifm_data.ifi_obytes
                        }
                    }
                }
            }

            next = next.advanced(by: msgLen)
        }

        return (totalUpload, totalDownload)
    }
}
