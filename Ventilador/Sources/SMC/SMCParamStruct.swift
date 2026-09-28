import Foundation

typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

/// Mirrors the AppleSMC user-client struct (80 bytes, `result` at offset 40).
struct SMCParamStruct {
    struct Version {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    struct PLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    enum Command {
        static let readBytes: UInt8 = 5
        static let writeBytes: UInt8 = 6
        static let readIndex: UInt8 = 8
        static let readKeyInfo: UInt8 = 9
    }

    static let selector: UInt32 = 2
    static let keyNotFound: UInt8 = 132

    var key: UInt32 = 0
    var version = Version()
    var pLimitData = PLimitData()
    var keyInfo = KeyInfo()
    /// Swift would otherwise pack `result` into KeyInfo's tail padding (offset 37, C expects 40).
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    )

    func payload(count: Int) -> [UInt8] {
        withUnsafeBytes(of: bytes) { Array($0.prefix(min(count, 32))) }
    }

    mutating func setPayload(_ payload: [UInt8]) {
        withUnsafeMutableBytes(of: &bytes) { $0.copyBytes(from: payload.prefix(32)) }
        keyInfo.dataSize = UInt32(min(payload.count, 32))
    }
}

enum FourCC {
    static func code(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    static func string(_ code: UInt32) -> String {
        String(decoding: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }, as: UTF8.self)
    }
}

enum SMCDataType {
    static let flt = FourCC.code("flt ")
    static let ui8 = FourCC.code("ui8 ")
    static let ui16 = FourCC.code("ui16")
    static let ui32 = FourCC.code("ui32")

    /// `flt ` is little-endian Float32 on Apple Silicon; `ui*` are big-endian.
    static func decode(_ bytes: [UInt8], type: UInt32) -> Double? {
        if type == flt, bytes.count == 4 {
            let bits = bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
            let value = Double(Float32(bitPattern: bits))
            return value.isFinite ? value : nil
        }
        if [ui8, ui16, ui32].contains(type), (1...4).contains(bytes.count) {
            return Double(bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        }
        return nil
    }

    static func encode(_ value: Double, type: UInt32) -> [UInt8]? {
        if type == flt {
            let bits = Float32(value).bitPattern
            return [0, 8, 16, 24].map { UInt8(truncatingIfNeeded: bits >> $0) }
        }
        if type == ui8 {
            return [UInt8(clamping: Int(value))]
        }
        return nil
    }
}
