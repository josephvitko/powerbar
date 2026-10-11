import Foundation
import IOKit

/// Minimal read-only client for the System Management Controller. Reading keys
/// doesn't need root. Used for whole-system power, which updates every few
/// seconds and works on AC too (the battery gauge refreshes about once a minute).
final class SMC {
    static let shared = SMC()

    private var connection: io_connect_t = 0
    private var keyInfo: [String: [UInt8]] = [:]   // cached 12-byte key info per key

    private init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        if IOServiceOpen(service, mach_task_self_, 0, &connection) != KERN_SUCCESS { connection = 0 }
    }

    /// Reads a key of type `flt ` (e.g. "PSTR" system power, "PPBR" battery power), in its native unit.
    func float(_ key: String) -> Float? {
        guard let bytes = read(key), bytes.count >= 4 else { return nil }
        return bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
    }

    // SMCParamStruct is 80 bytes: key @0, keyInfo @28 (dataSize u32, dataType u32, attributes u8),
    // result @40, data8 (command) @42, bytes @48.
    private func read(_ key: String) -> [UInt8]? {
        guard connection != 0, key.utf8.count == 4 else { return nil }
        var input = [UInt8](repeating: 0, count: 80)
        let code = key.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        withUnsafeBytes(of: code.littleEndian) { input.replaceSubrange(0..<4, with: $0) }

        if keyInfo[key] == nil {
            input[42] = 9   // kSMCGetKeyInfo
            guard let info = call(input) else { return nil }
            keyInfo[key] = Array(info[28..<40])
        }
        input.replaceSubrange(28..<40, with: keyInfo[key]!)
        input[42] = 5       // kSMCReadKey
        guard let out = call(input) else { return nil }
        let size = Int(input[28..<32].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        return Array(out[48..<48 + min(size, 32)])
    }

    private func call(_ input: [UInt8]) -> [UInt8]? {
        var input = input
        var output = [UInt8](repeating: 0, count: 80)
        var size = output.count
        guard IOConnectCallStructMethod(connection, 2, &input, input.count, &output, &size) == KERN_SUCCESS,
              output[40] == 0 else { return nil }
        return output
    }
}
