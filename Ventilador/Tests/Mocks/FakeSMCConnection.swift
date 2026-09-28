@testable import Ventilador
import Foundation

/// Simulates the AppleSMC key protocol (commands 5/6/8/9) over an in-memory key table, so
/// IOKitSMCController's real encode/decode/write logic runs without hardware. Thread-safe: the app-side
/// reader and the helper share one instance, like both processes share one SMC.
final class FakeSMCConnection: SMCConnection {
    struct Entry {
        var type: String
        var bytes: [UInt8]
    }

    private let lock = NSRecursiveLock()
    private var order: [String] = []
    private var table: [String: Entry] = [:]
    private var writes: [(key: String, value: Double)] = []
    private var indexCallCount = 0
    private var _transportError: FanControlError?
    private var _infoErrors: [String: UInt8] = [:]
    private var _readErrors: [String: UInt8] = [:]
    private var _rejectedWrites: Set<String> = []
    private var _rejectionsLeft: [String: Int] = [:]

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var transportError: FanControlError? {
        get { locked { _transportError } }
        set { locked { _transportError = newValue } }
    }
    var infoErrors: [String: UInt8] {
        get { locked { _infoErrors } }
        set { locked { _infoErrors = newValue } }
    }
    var readErrors: [String: UInt8] {
        get { locked { _readErrors } }
        set { locked { _readErrors = newValue } }
    }
    var rejectedWrites: Set<String> {
        get { locked { _rejectedWrites } }
        set { locked { _rejectedWrites = newValue } }
    }
    /// Rejects the next `count` writes to `key`, then accepts them (a transient SMC refusal).
    func reject(_ key: String, times count: Int) {
        locked { _rejectionsLeft[key] = count }
    }
    var writeLog: [(key: String, value: Double)] { locked { writes } }
    var indexCalls: Int { locked { indexCallCount } }

    func set(_ key: String, _ type: String, _ value: Double) {
        setRaw(key, type, SMCDataType.encode(value, type: FourCC.code(type)) ?? [])
    }

    func setRaw(_ key: String, _ type: String, _ bytes: [UInt8]) {
        locked {
            if table[key] == nil { order.append(key) }
            table[key] = Entry(type: type, bytes: bytes)
        }
    }

    func remove(_ key: String) {
        locked {
            table[key] = nil
            order.removeAll { $0 == key }
        }
    }

    func value(_ key: String) -> Double? {
        locked { table[key].flatMap { SMCDataType.decode($0.bytes, type: FourCC.code($0.type)) } }
    }

    /// The same SMC as seen by a non-root process: reads work, every write is refused.
    func readOnlyView() -> SMCConnection {
        ReadOnlySMC(base: self)
    }

    func call(_ input: SMCParamStruct) throws -> SMCParamStruct {
        lock.lock()
        defer { lock.unlock() }
        return try handle(input)
    }

    private func handle(_ input: SMCParamStruct) throws -> SMCParamStruct {
        if let _transportError { throw _transportError }
        var output = SMCParamStruct()
        let key = FourCC.string(input.key)
        switch input.data8 {
        case SMCParamStruct.Command.readIndex:
            indexCallCount += 1
            let index = Int(input.data32)
            if index < order.count { output.key = FourCC.code(order[index]) } else { output.result = SMCParamStruct.keyNotFound }
        case SMCParamStruct.Command.readKeyInfo:
            if let code = _infoErrors[key] {
                output.result = code
            } else if key == "#KEY" {
                output.keyInfo.dataSize = 4
                output.keyInfo.dataType = SMCDataType.ui32
            } else if let entry = table[key] {
                output.keyInfo.dataSize = UInt32(entry.bytes.count)
                output.keyInfo.dataType = FourCC.code(entry.type)
            } else {
                output.result = SMCParamStruct.keyNotFound
            }
        case SMCParamStruct.Command.readBytes:
            if let code = _readErrors[key] {
                output.result = code
            } else if key == "#KEY" {
                output.setPayload(withUnsafeBytes(of: UInt32(order.count).bigEndian) { Array($0) })
            } else if let entry = table[key] {
                output.setPayload(entry.bytes)
            } else {
                output.result = SMCParamStruct.keyNotFound
            }
        case SMCParamStruct.Command.writeBytes:
            let bytes = input.payload(count: Int(input.keyInfo.dataSize))
            if let left = _rejectionsLeft[key], left > 0 {
                _rejectionsLeft[key] = left - 1
                output.result = 0x87
            } else if _rejectedWrites.contains(key) {
                output.result = 0x87
            } else if var entry = table[key] {
                entry.bytes = bytes
                table[key] = entry
                writes.append((key, SMCDataType.decode(bytes, type: FourCC.code(entry.type)) ?? .nan))
            } else {
                output.result = SMCParamStruct.keyNotFound
            }
        default:
            output.result = 0x81
        }
        return output
    }

    /// Key layout observed on a live M4 Pro Mac mini, plus the junk sensors real hardware also exposes.
    static func appleSilicon(fans: [(min: Double, max: Double, actual: Double)] = [(1000, 4900, 1200)], ftst: Bool = false) -> FakeSMCConnection {
        let smc = FakeSMCConnection()
        smc.set("FNum", "ui8 ", Double(fans.count))
        for (index, fan) in fans.enumerated() {
            smc.set("F\(index)Ac", "flt ", fan.actual)
            smc.set("F\(index)Mn", "flt ", fan.min)
            smc.set("F\(index)Mx", "flt ", fan.max)
            smc.set("F\(index)Tg", "flt ", fan.min)
            smc.set("F\(index)Md", "ui8 ", 0)
        }
        if ftst { smc.set("Ftst", "ui8 ", 0) }
        smc.set("Tp01", "flt ", 70)
        smc.set("Tp05", "flt ", 80)
        smc.set("Te05", "flt ", 60)
        smc.set("Tg0f", "flt ", 55)
        smc.set("Tg0j", "flt ", 55)
        smc.set("TB0T", "flt ", 31)
        smc.set("Tp00", "flt ", -4)          // junk: negative
        smc.set("Tp0L", "flt ", 10)          // junk: below the 20 °C floor
        smc.set("Tz11", "flt ", 0)           // unknown group
        smc.setRaw("Tp0Z", "sp78", [0x3C, 0x00]) // CPU prefix but not flt
        smc.set("Tp0U", "ui8 ", 50)          // CPU prefix, integer-typed threshold constant, not a sensor
        return smc
    }
}

private final class ReadOnlySMC: SMCConnection {
    private let base: FakeSMCConnection

    init(base: FakeSMCConnection) {
        self.base = base
    }

    func call(_ input: SMCParamStruct) throws -> SMCParamStruct {
        guard input.data8 != SMCParamStruct.Command.writeBytes else {
            var refused = SMCParamStruct()
            refused.result = 0x86 // what a non-root client gets for a write
            return refused
        }
        return try base.call(input)
    }
}
