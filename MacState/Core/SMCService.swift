import Foundation
import IOKit

public final class SMCService {
    public static let shared = SMCService()

    private let lock = NSLock()
    private var connection: io_connect_t = 0

    // SMC selector — always use kernelIndex (2) for all operations
    private let kernelIndex: UInt32 = 2

    private let intelTemperatureKeys = ["TC0P", "TC0D", "TC0E", "TC0F"]
    private let appleSiliconTemperatureKeys = ["Tp09", "Tp0T", "Tp01", "Tp05"]

    private init() {
        openConnection()
    }

    deinit {
        closeConnection()
    }

    public func cpuTemperature() -> Double? {
        let keys = intelTemperatureKeys + appleSiliconTemperatureKeys
        for key in keys {
            if let value = readNumericValue(forKey: key), value > 0, value < 150 {
                return value
            }
        }
        return nil
    }

    public func fanCount() -> Int {
        guard let result = readValue(forKey: "FNum") else {
            return 0
        }

        switch result.dataType {
        case "ui8 ":
            return Int(result.bytes[0])
        case "ui16":
            guard result.bytes.count >= 2 else { return 0 }
            let raw = (UInt16(result.bytes[0]) << 8) | UInt16(result.bytes[1])
            return Int(raw)
        default:
            return Int(parseNumericValue(bytes: result.bytes, dataType: result.dataType) ?? 0)
        }
    }

    public func fanSpeed(index: Int) -> Double? {
        guard index >= 0 else { return nil }
        return readNumericValue(forKey: String(format: "F%dAc", index))
    }

    public func readKey(_ key: String) -> Double? {
        return readNumericValue(forKey: key)
    }

    public func allFanSpeeds() -> [(current: Double, min: Double, max: Double)] {
        let count = fanCount()
        guard count > 0 else { return [] }

        var output: [(current: Double, min: Double, max: Double)] = []
        output.reserveCapacity(count)

        for index in 0..<count {
            let current = readNumericValue(forKey: String(format: "F%dAc", index)) ?? 0
            let min = readNumericValue(forKey: String(format: "F%dMn", index)) ?? 0
            let max = readNumericValue(forKey: String(format: "F%dMx", index)) ?? 0
            output.append((current: current, min: min, max: max))
        }

        return output
    }

    // MARK: - SMC Connection

    private func openConnection() {
        lock.lock()
        defer { lock.unlock() }

        guard connection == 0 else { return }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        var openedConnection: io_connect_t = 0
        let result = IOServiceOpen(service, mach_task_self_, 0, &openedConnection)
        guard result == KERN_SUCCESS else { return }

        connection = openedConnection
    }

    private func closeConnection() {
        lock.lock()
        defer { lock.unlock() }

        guard connection != 0 else { return }
        IOServiceClose(connection)
        connection = 0
    }

    // MARK: - SMC Read

    private func readNumericValue(forKey key: String) -> Double? {
        guard let value = readValue(forKey: key) else {
            return nil
        }
        return parseNumericValue(bytes: value.bytes, dataType: value.dataType)
    }

    private func readValue(forKey key: String) -> SMCReadResult? {
        lock.lock()
        defer { lock.unlock() }

        guard connection != 0 else { return nil }
        guard let encodedKey = encodeSMCKey(key) else { return nil }

        var input = SMCKeyData()
        var output = SMCKeyData()

        // Step 1: Read key info (data8 = 9, selector = 2)
        input.key = encodedKey
        input.data8 = SMCCommand.readKeyInfo.rawValue

        guard callSMC(input: &input, output: &output) else {
            return nil
        }

        let keyInfo = output.keyInfo
        guard keyInfo.dataSize > 0, keyInfo.dataSize <= 32 else {
            return nil
        }

        // Step 2: Read bytes (data8 = 5, selector = 2)
        input.keyInfo.dataSize = keyInfo.dataSize
        input.data8 = SMCCommand.readBytes.rawValue

        guard callSMC(input: &input, output: &output) else {
            return nil
        }

        let count = Int(keyInfo.dataSize)
        return SMCReadResult(
            dataType: decodeSMCType(keyInfo.dataType),
            bytes: Array(output.bytesArray.prefix(count))
        )
    }

    /// Always calls with kernelIndex (2) as selector, matching Stats behavior
    private func callSMC(input: inout SMCKeyData, output: inout SMCKeyData) -> Bool {
        let inputSize = MemoryLayout<SMCKeyData>.stride
        var outputSize = MemoryLayout<SMCKeyData>.stride

        let result = IOConnectCallStructMethod(
            connection,
            kernelIndex,
            &input,
            inputSize,
            &output,
            &outputSize
        )

        return result == KERN_SUCCESS
    }

    // MARK: - Value Parsing

    private func parseNumericValue(bytes: [UInt8], dataType: String) -> Double? {
        guard !bytes.isEmpty else { return nil }

        switch dataType {
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
            let signed = Int16(bitPattern: raw)
            return Double(signed) / 256.0

        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
            return Double(raw) / 4.0

        case "flt ":
            guard bytes.count >= 4 else { return nil }
            var value: Float = 0
            // SMC flt type stores as native (little-endian on Intel, big-endian on Apple Silicon)
            // Use memcpy for correct byte interpretation
            var bytesCopy = Array(bytes.prefix(4))
            memcpy(&value, &bytesCopy, 4)
            return value.isFinite ? Double(value) : nil

        case "ui8 ":
            return Double(bytes[0])

        case "ui16":
            guard bytes.count >= 2 else { return nil }
            let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
            return Double(raw)

        case "ui32":
            guard bytes.count >= 4 else { return nil }
            let raw = (UInt32(bytes[0]) << 24)
                | (UInt32(bytes[1]) << 16)
                | (UInt32(bytes[2]) << 8)
                | UInt32(bytes[3])
            return Double(raw)

        case "si8 ":
            return Double(Int8(bitPattern: bytes[0]))

        case "si16":
            guard bytes.count >= 2 else { return nil }
            let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
            return Double(Int16(bitPattern: raw))

        case "sp1e":
            guard bytes.count >= 2 else { return nil }
            let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
            return Double(Int16(bitPattern: raw)) / 16384.0

        case "sp3c":
            guard bytes.count >= 2 else { return nil }
            let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
            return Double(Int16(bitPattern: raw)) / 4096.0

        case "sp4b":
            guard bytes.count >= 2 else { return nil }
            let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
            return Double(Int16(bitPattern: raw)) / 2048.0

        case "sp5a":
            guard bytes.count >= 2 else { return nil }
            let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
            return Double(Int16(bitPattern: raw)) / 1024.0

        case "sp69":
            guard bytes.count >= 2 else { return nil }
            let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
            return Double(Int16(bitPattern: raw)) / 512.0

        case "sp87":
            guard bytes.count >= 2 else { return nil }
            let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
            return Double(Int16(bitPattern: raw)) / 128.0

        case "spb4":
            guard bytes.count >= 2 else { return nil }
            let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
            return Double(Int16(bitPattern: raw)) / 16.0

        case "spf0":
            guard bytes.count >= 2 else { return nil }
            let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
            return Double(Int16(bitPattern: raw))

        case "fp1f":
            guard bytes.count >= 2 else { return nil }
            let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
            return Double(raw) / 32768.0

        case "fp4c":
            guard bytes.count >= 2 else { return nil }
            let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
            return Double(raw) / 4096.0

        case "fp5b":
            guard bytes.count >= 2 else { return nil }
            let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
            return Double(raw) / 2048.0

        case "fp6a":
            guard bytes.count >= 2 else { return nil }
            let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
            return Double(raw) / 1024.0

        case "fp79":
            guard bytes.count >= 2 else { return nil }
            let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
            return Double(raw) / 512.0

        case "fp88":
            guard bytes.count >= 2 else { return nil }
            let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
            return Double(raw) / 256.0

        case "fpa6":
            guard bytes.count >= 2 else { return nil }
            let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
            return Double(raw) / 64.0

        case "fpc4":
            guard bytes.count >= 2 else { return nil }
            let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
            return Double(raw) / 16.0

        default:
            return nil
        }
    }

    // MARK: - Key Encoding/Decoding

    private func encodeSMCKey(_ key: String) -> UInt32? {
        guard key.utf8.count == 4 else { return nil }
        return key.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private func decodeSMCType(_ raw: UInt32) -> String {
        let c1 = Character(UnicodeScalar((raw >> 24) & 0xFF) ?? " ")
        let c2 = Character(UnicodeScalar((raw >> 16) & 0xFF) ?? " ")
        let c3 = Character(UnicodeScalar((raw >> 8) & 0xFF) ?? " ")
        let c4 = Character(UnicodeScalar(raw & 0xFF) ?? " ")
        return String([c1, c2, c3, c4])
    }
}

// MARK: - SMC Data Structures (matching Stats/exelban layout exactly)

private enum SMCCommand: UInt8 {
    case readBytes = 5
    case writeBytes = 6
    case readIndex = 8
    case readKeyInfo = 9
    case readPLimit = 11
    case readVers = 12
}

private struct SMCReadResult {
    let dataType: String
    let bytes: [UInt8]
}

private struct SMCKeyDataVers {
    var major: CUnsignedChar = 0
    var minor: CUnsignedChar = 0
    var build: CUnsignedChar = 0
    var reserved: CUnsignedChar = 0
    var release: CUnsignedShort = 0
}

private struct SMCKeyDataPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyDataKeyInfo {
    var dataSize: IOByteCount32 = 0   // UInt32 via IOKit typedef
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
    // NO reserved field — this is critical!
}

private struct SMCKeyData {
    var key: UInt32 = 0
    var vers: SMCKeyDataVers = SMCKeyDataVers()
    var pLimitData: SMCKeyDataPLimitData = SMCKeyDataPLimitData()
    var keyInfo: SMCKeyDataKeyInfo = SMCKeyDataKeyInfo()
    var padding: UInt16 = 0           // UInt16, NOT UInt32!
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

    var bytesArray: [UInt8] {
        [
            bytes.0, bytes.1, bytes.2, bytes.3,
            bytes.4, bytes.5, bytes.6, bytes.7,
            bytes.8, bytes.9, bytes.10, bytes.11,
            bytes.12, bytes.13, bytes.14, bytes.15,
            bytes.16, bytes.17, bytes.18, bytes.19,
            bytes.20, bytes.21, bytes.22, bytes.23,
            bytes.24, bytes.25, bytes.26, bytes.27,
            bytes.28, bytes.29, bytes.30, bytes.31
        ]
    }
}
