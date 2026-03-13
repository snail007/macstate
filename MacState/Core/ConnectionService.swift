import Foundation
import Darwin

struct ConnectionInfo {
    let fd: Int32
    let protocolName: String
    let familyName: String
    let localAddress: String
    let localPort: Int
    let remoteAddress: String
    let remotePort: Int
    let state: String
    let bytesIn: UInt32
    let bytesOut: UInt32
    let remoteGeo: String
}

final class ConnectionService {
    static let shared = ConnectionService()

    private init() {}

    func connections(forPid pid: Int32) -> [ConnectionInfo] {
        let bufSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufSize > 0 else { return [] }

        let fdInfoSize = MemoryLayout<proc_fdinfo>.stride
        let fdCount = Int(bufSize) / fdInfoSize
        guard fdCount > 0 else { return [] }

        let buffer = UnsafeMutablePointer<proc_fdinfo>.allocate(capacity: fdCount)
        defer { buffer.deallocate() }

        let actualSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer, bufSize)
        guard actualSize > 0 else { return [] }

        let actualCount = Int(actualSize) / fdInfoSize
        var results: [ConnectionInfo] = []

        for i in 0..<actualCount {
            let fdInfo = buffer[i]
            guard fdInfo.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) else { continue }

            var socketInfo = socket_fdinfo()
            let socketInfoSize = Int32(MemoryLayout<socket_fdinfo>.stride)
            let ret = proc_pidfdinfo(pid, fdInfo.proc_fd, PROC_PIDFDSOCKETINFO, &socketInfo, socketInfoSize)
            guard ret == socketInfoSize else { continue }

            let family = socketInfo.psi.soi_family
            guard family == AF_INET || family == AF_INET6 else { continue }

            let kind = socketInfo.psi.soi_kind
            let familyName = family == AF_INET ? "IPv4" : "IPv6"

            if kind == SOCKINFO_TCP {
                let tcp = socketInfo.psi.soi_proto.pri_tcp
                let ini = tcp.tcpsi_ini
                let lport = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport)))
                let fport = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_fport)))
                let localAddr = formatLocalAddress(ini, vflag: ini.insi_vflag)
                let remoteAddr = formatForeignAddress(ini, vflag: ini.insi_vflag)
                let state = tcpStateName(tcp.tcpsi_state)
                let bytesIn = socketInfo.psi.soi_rcv.sbi_cc
                let bytesOut = socketInfo.psi.soi_snd.sbi_cc

                results.append(ConnectionInfo(
                    fd: fdInfo.proc_fd,
                    protocolName: "TCP",
                    familyName: familyName,
                    localAddress: localAddr,
                    localPort: lport,
                    remoteAddress: remoteAddr,
                    remotePort: fport,
                    state: state,
                    bytesIn: bytesIn,
                    bytesOut: bytesOut,
                    remoteGeo: IP2RegionService.shared.search(remoteAddr) ?? ""
                ))
            } else if kind == SOCKINFO_IN {
                let ini = socketInfo.psi.soi_proto.pri_in
                let lport = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport)))
                let fport = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_fport)))
                let localAddr = formatLocalAddress(ini, vflag: ini.insi_vflag)
                let remoteAddr = formatForeignAddress(ini, vflag: ini.insi_vflag)
                let bytesIn = socketInfo.psi.soi_rcv.sbi_cc
                let bytesOut = socketInfo.psi.soi_snd.sbi_cc

                results.append(ConnectionInfo(
                    fd: fdInfo.proc_fd,
                    protocolName: "UDP",
                    familyName: familyName,
                    localAddress: localAddr,
                    localPort: lport,
                    remoteAddress: remoteAddr,
                    remotePort: fport,
                    state: "",
                    bytesIn: bytesIn,
                    bytesOut: bytesOut,
                    remoteGeo: IP2RegionService.shared.search(remoteAddr) ?? ""
                ))
            }
        }

        return results
    }

    private func formatLocalAddress(_ ini: in_sockinfo, vflag: UInt8) -> String {
        if vflag & UInt8(INI_IPV4) != 0 {
            var ip4 = ini.insi_laddr.ina_46.i46a_addr4
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &ip4, &buf, socklen_t(INET_ADDRSTRLEN))
            return String(cString: buf)
        } else if vflag & UInt8(INI_IPV6) != 0 {
            var ip6 = ini.insi_laddr.ina_6
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            inet_ntop(AF_INET6, &ip6, &buf, socklen_t(INET6_ADDRSTRLEN))
            return String(cString: buf)
        }
        return "*"
    }

    private func formatForeignAddress(_ ini: in_sockinfo, vflag: UInt8) -> String {
        if vflag & UInt8(INI_IPV4) != 0 {
            var ip4 = ini.insi_faddr.ina_46.i46a_addr4
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &ip4, &buf, socklen_t(INET_ADDRSTRLEN))
            return String(cString: buf)
        } else if vflag & UInt8(INI_IPV6) != 0 {
            var ip6 = ini.insi_faddr.ina_6
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            inet_ntop(AF_INET6, &ip6, &buf, socklen_t(INET6_ADDRSTRLEN))
            return String(cString: buf)
        }
        return "*"
    }

    private func tcpStateName(_ state: Int32) -> String {
        switch state {
        case TSI_S_CLOSED: return "CLOSED"
        case TSI_S_LISTEN: return "LISTEN"
        case TSI_S_SYN_SENT: return "SYN_SENT"
        case TSI_S_SYN_RECEIVED: return "SYN_RCVD"
        case TSI_S_ESTABLISHED: return "ESTAB"
        case TSI_S__CLOSE_WAIT: return "CLOSE_WAIT"
        case TSI_S_FIN_WAIT_1: return "FIN_WAIT_1"
        case TSI_S_CLOSING: return "CLOSING"
        case TSI_S_LAST_ACK: return "LAST_ACK"
        case TSI_S_FIN_WAIT_2: return "FIN_WAIT_2"
        case TSI_S_TIME_WAIT: return "TIME_WAIT"
        default: return "UNKNOWN"
        }
    }

    static func formatBytes(_ bytes: UInt32) -> String {
        if bytes == 0 { return "0 B" }
        let kb = Double(bytes) / 1024
        if kb < 1 { return "\(bytes) B" }
        let mb = kb / 1024
        if mb < 1 { return String(format: "%.1f KB", kb) }
        let gb = mb / 1024
        if gb < 1 { return String(format: "%.1f MB", mb) }
        return String(format: "%.2f GB", gb)
    }
}
