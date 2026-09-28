import Foundation

/// Reads work as any user; writes need root, so only the privileged helper calls the write paths.
final class IOKitSMCController: FanControlling {
    // Calibration knobs, derived from a live M4 Pro key dump and a 30 s sampling run:
    // many T-keys read 0 or negative (dropped below the floor); real hot sensors are capped at the ceiling
    // rather than dropped, so they still push cooling up; the CPU (112 sensors) and GPU (22) groups never
    // held all values still for more than 0.85 s, so a whole group unchanged for seconds means frozen data.
    // "Tf" joins the CPU group: M3-family SMCs are reported to keep P-core (and some GPU) sensors there, and
    // leaving them out would let cooler E-cores alone drive a profile. Verify on each generation.
    static let groupByPrefix = [
        "Tp": TemperatureReading.cpuGroup, "Te": TemperatureReading.cpuGroup, "Tf": TemperatureReading.cpuGroup,
        "Tg": TemperatureReading.gpuGroup, "TB": "Battery",
    ]
    static let floorCelsius = 20.0
    static let ceilingCelsius = 110.0
    static let changeTrackedGroups: Set = [TemperatureReading.cpuGroup, TemperatureReading.gpuGroup]
    static let plausibleRPM = 0.0..<100_000.0

    private let smc: SMCConnection
    private let clock: () -> Date
    private var temperatureKeys: [String: String]?
    private var groupSnapshots: [String: (raw: [UInt8], changedAt: Date)] = [:]
    /// Last fan count seen, so a revert can still reach every fan if FNum becomes unreadable.
    private var knownFanCount = 0

    init(connection: SMCConnection, clock: @escaping () -> Date = Date.init) {
        smc = connection
        self.clock = clock
    }

    func discoverFans() throws -> [Fan] {
        guard let count = try readValue("FNum") else { return [] }
        knownFanCount = Int(count)
        return try (0..<knownFanCount).map { index in
            guard let rpm = try readValue("F\(index)Ac"),
                  let low = try readValue("F\(index)Mn"),
                  let high = try readValue("F\(index)Mx"),
                  [rpm, low, high].allSatisfy({ Self.plausibleRPM.contains($0) }),
                  let fan = Fan(id: "\(index)", label: "Fan \(index + 1)", currentRPM: Int(rpm.rounded()),
                                minSafeRPM: Int(low.rounded(.up)), maxSafeRPM: Int(high.rounded(.down)),
                                targetRPM: try readValue("F\(index)Tg").flatMap { Self.wholeRPM($0) },
                                isManual: try readValue("F\(index)Md").map { $0 == 1 })
            else { throw FanControlError.sensorUnavailable(detail: "Fan \(index + 1) reports no valid speed range") }
            return fan
        }
    }

    /// One reading per sensor group: the average of its sensors at or above the floor, capped at the ceiling.
    func readTemperatures() throws -> [TemperatureReading] {
        let now = clock()
        var values: [String: [Double]] = [:]
        var raw: [String: [UInt8]] = [:]
        for (key, label) in try discoveredTemperatureKeys().sorted(by: { $0.key < $1.key }) {
            guard let (type, bytes) = try readBytes(key) else { continue }
            raw[label, default: []] += bytes
            if let celsius = SMCDataType.decode(bytes, type: type), celsius >= Self.floorCelsius {
                values[label, default: []].append(min(celsius, Self.ceilingCelsius))
            }
        }
        guard !values.isEmpty else { throw FanControlError.sensorUnavailable(detail: "no plausible temperature sensors") }
        return values
            .map { TemperatureReading(sourceLabel: $0.key, celsius: $0.value.reduce(0, +) / Double($0.value.count), readAt: liveSince($0.key, raw[$0.key]!, now: now)) }
            .sorted { $0.sourceLabel < $1.sourceLabel }
    }

    // Calibration knob: Ftst ("force test") unlocks manual targets on some Apple Silicon
    // generations and is absent on others (e.g. M4 Pro); verify writes on target hardware.
    func setTargetRPM(fanID: Fan.ID, rpm: Int) throws {
        guard let fan = try discoverFans().first(where: { $0.id == fanID }) else {
            throw FanControlError.writeFailed(detail: "unknown fan \(fanID)")
        }
        guard (fan.minSafeRPM...fan.maxSafeRPM).contains(rpm) else {
            throw FanControlError.writeFailed(detail: "\(rpm) RPM is outside \(fan.label)'s safe range")
        }
        if try keyInfo("Ftst") != nil { try write("Ftst", 1) }
        try write("F\(fanID)Md", 1)
        try write("F\(fanID)Tg", Double(rpm))
    }

    /// Attempts every step even if one fails (falling back to the last known fan count when FNum is
    /// unreadable), then reports the first failure so the caller keeps trying.
    func revertToAutomatic() throws {
        var firstError: Error?
        do {
            if let count = try readValue("FNum") {
                knownFanCount = Int(count)
            } else if knownFanCount > 0 {
                firstError = FanControlError.writeFailed(detail: "fan count unreadable")
            }
        } catch {
            firstError = error
        }
        for index in 0..<knownFanCount {
            do { try write("F\(index)Md", 0) } catch { firstError = firstError ?? error }
        }
        do {
            if try keyInfo("Ftst") != nil { try write("Ftst", 0) }
        } catch {
            firstError = firstError ?? error
        }
        if let firstError { throw firstError }
    }

    func detectsConflictingController() -> Bool {
        let count = Int((try? readValue("FNum")) ?? 0)
        let manualFan = (0..<count).contains { (try? readValue("F\($0)Md")) == 1 }
        return manualFan || (try? readValue("Ftst")) == 1
    }

    private static func wholeRPM(_ value: Double) -> Int? {
        plausibleRPM.contains(value) ? Int(value.rounded()) : nil
    }

    /// Change-tracked groups report when their raw values last changed, so a frozen group ages past the
    /// staleness threshold (FR-013); other groups report the read time.
    private func liveSince(_ group: String, _ raw: [UInt8], now: Date) -> Date {
        guard Self.changeTrackedGroups.contains(group) else { return now }
        if let snapshot = groupSnapshots[group], snapshot.raw == raw { return snapshot.changedAt }
        groupSnapshots[group] = (raw, now)
        return now
    }

    private func discoveredTemperatureKeys() throws -> [String: String] {
        if let temperatureKeys { return temperatureKeys }
        guard let count = try readValue("#KEY") else { throw FanControlError.sensorUnavailable(detail: "SMC key index unavailable") }
        var keys: [String: String] = [:]
        for index in 0..<UInt32(count) {
            var input = SMCParamStruct()
            input.data8 = SMCParamStruct.Command.readIndex
            input.data32 = index
            let key = FourCC.string(try smc.call(input).key)
            if let label = Self.groupByPrefix[String(key.prefix(2))], try keyInfo(key)?.dataType == SMCDataType.flt {
                keys[key] = label
            }
        }
        temperatureKeys = keys
        return keys
    }

    private func keyInfo(_ key: String) throws -> SMCParamStruct.KeyInfo? {
        var input = SMCParamStruct()
        input.key = FourCC.code(key)
        input.data8 = SMCParamStruct.Command.readKeyInfo
        let output = try smc.call(input)
        if output.result == SMCParamStruct.keyNotFound { return nil }
        guard output.result == 0 else { throw FanControlError.sensorUnavailable(detail: "SMC key \(key) info error \(output.result)") }
        return output.keyInfo
    }

    private func readBytes(_ key: String) throws -> (type: UInt32, bytes: [UInt8])? {
        guard let info = try keyInfo(key) else { return nil }
        var input = SMCParamStruct()
        input.key = FourCC.code(key)
        input.keyInfo.dataSize = info.dataSize
        input.data8 = SMCParamStruct.Command.readBytes
        let output = try smc.call(input)
        guard output.result == 0 else { throw FanControlError.sensorUnavailable(detail: "SMC key \(key) read error \(output.result)") }
        return (info.dataType, output.payload(count: Int(info.dataSize)))
    }

    private func readValue(_ key: String) throws -> Double? {
        try readBytes(key).flatMap { SMCDataType.decode($0.bytes, type: $0.type) }
    }

    private func write(_ key: String, _ value: Double) throws {
        guard let info = try keyInfo(key), let payload = SMCDataType.encode(value, type: info.dataType) else {
            throw FanControlError.writeFailed(detail: "SMC key \(key) is not writable")
        }
        var input = SMCParamStruct()
        input.key = FourCC.code(key)
        input.data8 = SMCParamStruct.Command.writeBytes
        input.setPayload(payload)
        let output = try smc.call(input)
        guard output.result == 0 else { throw FanControlError.writeFailed(detail: "SMC rejected \(key) (error \(output.result))") }
    }
}
