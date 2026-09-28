@testable import Ventilador
import IOKit
import XCTest

@MainActor final class SMCParamStructTests: XCTestCase {
    /// The kernel reads this struct byte-for-byte; a layout drift corrupts every SMC call.
    func test_layoutMatchesTheAppleSMCUserClient() {
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.size, 80)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.stride, 80)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.offset(of: \.keyInfo), 28)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.offset(of: \.result), 40)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.offset(of: \.status), 41)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.offset(of: \.data8), 42)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.offset(of: \.data32), 44)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.offset(of: \.bytes), 48)
    }

    /// AppleSMC's command numbers are a hardware protocol, not a choice: a wrong byte breaks every write.
    func test_protocolConstantsMatchAppleSMC() {
        XCTAssertEqual(SMCParamStruct.selector, 2)
        XCTAssertEqual(SMCParamStruct.Command.readBytes, 5)
        XCTAssertEqual(SMCParamStruct.Command.writeBytes, 6)
        XCTAssertEqual(SMCParamStruct.Command.readIndex, 8)
        XCTAssertEqual(SMCParamStruct.Command.readKeyInfo, 9)
        XCTAssertEqual(SMCParamStruct.keyNotFound, 132)
    }

    func test_fourCCRoundTrip() {
        XCTAssertEqual(FourCC.code("F0Ac"), 0x4630_4163)
        XCTAssertEqual(FourCC.string(0x4630_4163), "F0Ac")
        XCTAssertEqual(FourCC.string(FourCC.code("flt ")), "flt ")
    }

    func test_decodeKnownTypes() {
        XCTAssertEqual(SMCDataType.decode(SMCDataType.encode(1234.5, type: SMCDataType.flt)!, type: SMCDataType.flt), 1234.5)
        XCTAssertEqual(SMCDataType.decode([0x00, 0x00, 0x7A, 0x44], type: SMCDataType.flt), 1000, "little-endian Float32")
        XCTAssertEqual(SMCDataType.decode([7], type: SMCDataType.ui8), 7)
        XCTAssertEqual(SMCDataType.decode([0x01, 0x02], type: SMCDataType.ui16), 258, "big-endian")
        XCTAssertEqual(SMCDataType.decode([0x00, 0x00, 0x06, 0xC0], type: SMCDataType.ui32), 1728)
    }

    func test_decodeRejectsUnknownTypesWrongSizesAndNonFiniteFloats() {
        XCTAssertNil(SMCDataType.decode([0x3C, 0x00], type: FourCC.code("sp78")))
        XCTAssertNil(SMCDataType.decode([0, 0], type: SMCDataType.flt))
        XCTAssertNil(SMCDataType.decode([], type: SMCDataType.ui8))
        XCTAssertNil(SMCDataType.decode(SMCDataType.encode(.nan, type: SMCDataType.flt)!, type: SMCDataType.flt))
        XCTAssertNil(SMCDataType.decode(SMCDataType.encode(.infinity, type: SMCDataType.flt)!, type: SMCDataType.flt))
        XCTAssertNil(SMCDataType.decode([0x00, 0x00, 0x7A, 0x44, 0x00], type: SMCDataType.flt), "a flt payload is exactly 4 bytes")
    }

    func test_encodeWritableTypesOnly() {
        XCTAssertEqual(SMCDataType.encode(1000, type: SMCDataType.flt), [0x00, 0x00, 0x7A, 0x44])
        XCTAssertEqual(SMCDataType.encode(1, type: SMCDataType.ui8), [1])
        XCTAssertEqual(SMCDataType.encode(300, type: SMCDataType.ui8), [255])
        XCTAssertNil(SMCDataType.encode(1, type: SMCDataType.ui16))
    }

    func test_payloadRoundTripAndBounds() {
        var param = SMCParamStruct()
        param.setPayload([1, 2, 3])
        XCTAssertEqual(param.keyInfo.dataSize, 3)
        XCTAssertEqual(param.payload(count: 3), [1, 2, 3])
        param.setPayload(Array(repeating: 9, count: 40))
        XCTAssertEqual(param.keyInfo.dataSize, 32)
        XCTAssertEqual(param.payload(count: 99).count, 32)
    }
}

@MainActor final class IOKitSMCControllerTests: XCTestCase {
    private let clock = TestClock()

    private func controller(_ smc: SMCConnection) -> IOKitSMCController {
        IOKitSMCController(connection: smc, clock: clock.read)
    }

    func test_discoverFans_readsEveryFanWithItsSafeRangeAndTarget() throws {
        let smc = FakeSMCConnection.appleSilicon(fans: [(1000.4, 4900.6, 1234.4), (1200, 6000, 2000)])
        smc.set("F1Tg", "flt ", 2500.4)
        smc.set("F1Md", "ui8 ", 1)
        let fans = try controller(smc).discoverFans()
        XCTAssertEqual(fans, [
            Fan(id: "0", label: "Fan 1", currentRPM: 1234, minSafeRPM: 1001, maxSafeRPM: 4900, targetRPM: 1000, isManual: false),
            Fan(id: "1", label: "Fan 2", currentRPM: 2000, minSafeRPM: 1200, maxSafeRPM: 6000, targetRPM: 2500, isManual: true),
        ], "safe range rounded inward, never outward")
    }

    func test_discoverFans_targetReadErrorsFailClosed() {
        let smc = FakeSMCConnection.appleSilicon()
        smc.readErrors["F0Tg"] = 0x85
        XCTAssertThrowsError(try controller(smc).discoverFans(), "an unreadable target would hide another writer")
    }

    func test_discoverFans_unreadableTargetIsUnknownNotAnError() throws {
        let smc = FakeSMCConnection.appleSilicon()
        smc.set("F0Tg", "flt ", 250_000)
        XCTAssertNil(try controller(smc).discoverFans().first?.targetRPM)
        smc.remove("F0Tg")
        XCTAssertNil(try controller(smc).discoverFans().first?.targetRPM)
    }

    func test_discoverFans_fanlessMacIsEmptyNotAnError() throws {
        let smc = FakeSMCConnection.appleSilicon(fans: [])
        XCTAssertEqual(try controller(smc).discoverFans(), [])
        smc.remove("FNum")
        XCTAssertEqual(try controller(smc).discoverFans(), [])
    }

    func test_discoverFans_invalidMissingOrNonsenseRangeIsAnError() {
        let inverted = FakeSMCConnection.appleSilicon(fans: [(5000, 1000, 1200)])
        XCTAssertThrowsError(try controller(inverted).discoverFans()) {
            XCTAssertEqual($0 as? FanControlError, .sensorUnavailable(detail: "Fan 1 reports no valid speed range"))
        }
        let missing = FakeSMCConnection.appleSilicon()
        missing.remove("F0Mx")
        XCTAssertThrowsError(try controller(missing).discoverFans())
        let nonsense = FakeSMCConnection.appleSilicon()
        nonsense.set("F0Mx", "flt ", 3e9)
        XCTAssertThrowsError(try controller(nonsense).discoverFans(), "absurd values fail closed instead of trapping")
        let notANumber = FakeSMCConnection.appleSilicon()
        notANumber.set("F0Ac", "flt ", .nan)
        XCTAssertThrowsError(try controller(notANumber).discoverFans())
        let negative = FakeSMCConnection.appleSilicon()
        negative.set("F0Mn", "flt ", -5)
        XCTAssertThrowsError(try controller(negative).discoverFans())
        let hugeSpeed = FakeSMCConnection.appleSilicon()
        hugeSpeed.set("F0Ac", "flt ", 1e20)
        XCTAssertThrowsError(try controller(hugeSpeed).discoverFans(), "a garbage current speed fails closed instead of trapping")
        let negativeSpeed = FakeSMCConnection.appleSilicon()
        negativeSpeed.set("F0Ac", "flt ", -3)
        XCTAssertThrowsError(try controller(negativeSpeed).discoverFans())
    }

    func test_readTemperatures_averagesSensorsPerGroupAndIgnoresJunk() throws {
        let smc = FakeSMCConnection.appleSilicon()
        let readings = try controller(smc).readTemperatures()
        XCTAssertEqual(readings, [
            TemperatureReading(sourceLabel: "Battery", celsius: 31, readAt: clock.now),
            TemperatureReading(sourceLabel: "CPU", celsius: 70, readAt: clock.now),
            TemperatureReading(sourceLabel: "GPU", celsius: 55, readAt: clock.now),
        ], "negative, below-floor, integer-typed, non-flt and unknown-group keys are ignored")
    }

    func test_readTemperatures_capsHotSensorsInsteadOfDroppingThem() throws {
        let smc = FakeSMCConnection.appleSilicon()
        smc.set("Tp09", "flt ", 150)
        let cpu = try controller(smc).readTemperatures().first { $0.sourceLabel == "CPU" }
        XCTAssertEqual(cpu?.celsius, (70 + 80 + 60 + 110) / 4, "a hot sensor still pushes cooling up, capped at 110 °C")
    }

    func test_readTemperatures_floorIsInclusive() throws {
        let smc = FakeSMCConnection()
        smc.set("Tp01", "flt ", IOKitSMCController.floorCelsius)
        XCTAssertEqual(try controller(smc).readTemperatures().first?.celsius, 20)
    }

    /// FR-013: a change-tracked group whose raw values stop changing keeps its old timestamp.
    func test_readTemperatures_frozenGroupsKeepTheTimeOfTheirLastChange() throws {
        let smc = FakeSMCConnection.appleSilicon()
        let controller = controller(smc)
        let start = clock.now
        _ = try controller.readTemperatures()

        clock.advance(10)
        smc.set("Tp05", "flt ", 81)
        let readings = try controller.readTemperatures()

        XCTAssertEqual(readings.first { $0.sourceLabel == "CPU" }?.readAt, clock.now, "changed: fresh")
        XCTAssertEqual(readings.first { $0.sourceLabel == "GPU" }?.readAt, start, "unchanged: keeps its age")
        XCTAssertEqual(readings.first { $0.sourceLabel == "Battery" }?.readAt, clock.now, "not change-tracked: a steady battery is normal")
        XCTAssertEqual(IOKitSMCController.changeTrackedGroups, ["CPU", "GPU"])

        let changedAt = clock.now
        clock.advance(2)
        let later = try controller.readTemperatures()
        XCTAssertEqual(later.first { $0.sourceLabel == "CPU" }?.readAt, changedAt, "age counts from the latest change, not the first read")
    }

    func test_readTemperatures_efficiencyAndPerformanceCorePrefixesAreBothCPU() throws {
        let smc = FakeSMCConnection()
        smc.set("Te05", "flt ", 50)
        smc.set("Tf04", "flt ", 90) // P-cores on M3-family SMCs
        let readings = try controller(smc).readTemperatures()
        XCTAssertEqual(readings.map(\.sourceLabel), ["CPU"])
        XCTAssertEqual(readings.first?.celsius, 70)
    }

    func test_readTemperatures_discoversKeysOnceAndToleratesVanishedKeys() throws {
        let smc = FakeSMCConnection.appleSilicon()
        let controller = controller(smc)
        _ = try controller.readTemperatures()
        let indexCalls = smc.indexCalls
        smc.remove("Tg0f")
        smc.remove("Tg0j")

        let readings = try controller.readTemperatures()

        XCTAssertEqual(smc.indexCalls, indexCalls, "key enumeration is cached")
        XCTAssertEqual(readings.map(\.sourceLabel), ["Battery", "CPU"])
    }

    func test_readTemperatures_failsWithoutKeyIndexOrPlausibleSensors() {
        let noIndex = FakeSMCConnection.appleSilicon()
        noIndex.infoErrors["#KEY"] = SMCParamStruct.keyNotFound
        XCTAssertThrowsError(try controller(noIndex).readTemperatures()) {
            XCTAssertEqual($0 as? FanControlError, .sensorUnavailable(detail: "SMC key index unavailable"))
        }
        let junkOnly = FakeSMCConnection()
        junkOnly.set("Tp00", "flt ", -4)
        junkOnly.set("Tp0L", "flt ", 19.9)
        XCTAssertThrowsError(try controller(junkOnly).readTemperatures()) {
            XCTAssertEqual($0 as? FanControlError, .sensorUnavailable(detail: "no plausible temperature sensors"))
        }
    }

    func test_setTargetRPM_unlocksAndWritesModeThenTarget() throws {
        let withUnlock = FakeSMCConnection.appleSilicon(ftst: true)
        try controller(withUnlock).setTargetRPM(fanID: "0", rpm: 3000)
        XCTAssertEqual(withUnlock.writeLog.map(\.key), ["Ftst", "F0Md", "F0Tg"])
        XCTAssertEqual(withUnlock.writeLog.map(\.value), [1, 1, 3000])

        let withoutUnlock = FakeSMCConnection.appleSilicon()
        try controller(withoutUnlock).setTargetRPM(fanID: "0", rpm: 3000)
        XCTAssertEqual(withoutUnlock.writeLog.map(\.key), ["F0Md", "F0Tg"], "M4-style SMC has no Ftst")
    }

    /// Each fan is written through its own keys, validated against its own range.
    func test_setTargetRPM_writesTheRequestedFanOnly() throws {
        let smc = FakeSMCConnection.appleSilicon(fans: [(1000, 4900, 1200), (1200, 6000, 2000)])
        try controller(smc).setTargetRPM(fanID: "1", rpm: 5500)
        XCTAssertEqual(smc.writeLog.map(\.key), ["F1Md", "F1Tg"])
        XCTAssertEqual(smc.value("F1Tg"), 5500)
        XCTAssertEqual(smc.value("F0Md"), 0)
        XCTAssertEqual(smc.value("F0Tg"), 1000)
    }

    func test_setTargetRPM_refusesUnknownFansAndUnsafeSpeedsOnBothSides() {
        let smc = FakeSMCConnection.appleSilicon()
        XCTAssertThrowsError(try controller(smc).setTargetRPM(fanID: "3", rpm: 2000)) {
            XCTAssertEqual($0 as? FanControlError, .writeFailed(detail: "unknown fan 3"))
        }
        XCTAssertThrowsError(try controller(smc).setTargetRPM(fanID: "0", rpm: 5000)) {
            XCTAssertEqual($0 as? FanControlError, .writeFailed(detail: "5000 RPM is outside Fan 1's safe range"))
        }
        XCTAssertThrowsError(try controller(smc).setTargetRPM(fanID: "0", rpm: 999)) {
            XCTAssertEqual($0 as? FanControlError, .writeFailed(detail: "999 RPM is outside Fan 1's safe range"))
        }
        XCTAssertTrue(smc.writeLog.isEmpty, "nothing written before validation passes")
    }

    func test_setTargetRPM_reportsRejectedAndUnwritableKeys() {
        let rejected = FakeSMCConnection.appleSilicon()
        rejected.rejectedWrites = ["F0Md"]
        XCTAssertThrowsError(try controller(rejected).setTargetRPM(fanID: "0", rpm: 2000)) {
            XCTAssertEqual($0 as? FanControlError, .writeFailed(detail: "SMC rejected F0Md (error 135)"))
        }
        let unlockRejected = FakeSMCConnection.appleSilicon(ftst: true)
        unlockRejected.rejectedWrites = ["Ftst"]
        XCTAssertThrowsError(try controller(unlockRejected).setTargetRPM(fanID: "0", rpm: 2000), "a failed unlock is not an override")
        XCTAssertTrue(unlockRejected.writeLog.isEmpty)
        let wrongType = FakeSMCConnection.appleSilicon()
        wrongType.setRaw("F0Md", "ui16", [0, 0])
        XCTAssertThrowsError(try controller(wrongType).setTargetRPM(fanID: "0", rpm: 2000)) {
            XCTAssertEqual($0 as? FanControlError, .writeFailed(detail: "SMC key F0Md is not writable"))
        }
        let missing = FakeSMCConnection.appleSilicon()
        missing.remove("F0Tg")
        XCTAssertThrowsError(try controller(missing).setTargetRPM(fanID: "0", rpm: 2000)) {
            XCTAssertEqual($0 as? FanControlError, .writeFailed(detail: "SMC key F0Tg is not writable"))
        }
    }

    func test_nonRootWritesAreRefused() {
        let smc = FakeSMCConnection.appleSilicon()
        XCTAssertThrowsError(try controller(smc.readOnlyView()).setTargetRPM(fanID: "0", rpm: 2000)) {
            XCTAssertEqual($0 as? FanControlError, .writeFailed(detail: "SMC rejected F0Md (error 134)"))
        }
    }

    func test_revertToAutomatic_resetsEveryFanAndTheUnlock() throws {
        let smc = FakeSMCConnection.appleSilicon(fans: [(1000, 4900, 1200), (1200, 6000, 2000)], ftst: true)
        try controller(smc).setTargetRPM(fanID: "1", rpm: 3000)

        try controller(smc).revertToAutomatic()

        XCTAssertEqual(smc.value("F0Md"), 0)
        XCTAssertEqual(smc.value("F1Md"), 0)
        XCTAssertEqual(smc.value("Ftst"), 0)
    }

    func test_revertToAutomatic_keepsGoingPastFailuresThenReportsTheFirst() {
        let smc = FakeSMCConnection.appleSilicon(fans: [(1000, 4900, 1200), (1200, 6000, 2000)], ftst: true)
        smc.set("F1Md", "ui8 ", 1)
        smc.set("Ftst", "ui8 ", 1)
        smc.rejectedWrites = ["F0Md", "Ftst"]

        XCTAssertThrowsError(try controller(smc).revertToAutomatic()) {
            XCTAssertEqual($0 as? FanControlError, .writeFailed(detail: "SMC rejected F0Md (error 135)"))
        }
        XCTAssertEqual(smc.value("F1Md"), 0, "the other fan still returned to automatic")

        let unlockOnly = FakeSMCConnection.appleSilicon(ftst: true)
        unlockOnly.rejectedWrites = ["Ftst"]
        XCTAssertThrowsError(try controller(unlockOnly).revertToAutomatic())
        XCTAssertEqual(unlockOnly.value("F0Md"), 0)

        let bothFans = FakeSMCConnection.appleSilicon(fans: [(1000, 4900, 1200), (1200, 6000, 2000)])
        bothFans.rejectedWrites = ["F0Md", "F1Md"]
        XCTAssertThrowsError(try controller(bothFans).revertToAutomatic()) {
            XCTAssertEqual($0 as? FanControlError, .writeFailed(detail: "SMC rejected F0Md (error 135)"), "the first failure, not the last")
        }
    }

    /// FRESH-4: a fan count that reads as missing after discovery still reverts every known fan and reports it.
    func test_revertToAutomatic_vanishedFanCountStillRevertsKnownFans() throws {
        let smc = FakeSMCConnection.appleSilicon(fans: [(1000, 4900, 1200), (1200, 6000, 2000)])
        let controller = controller(smc)
        _ = try controller.discoverFans()
        smc.set("F0Md", "ui8 ", 1)
        smc.set("F1Md", "ui8 ", 1)
        smc.remove("FNum")

        XCTAssertThrowsError(try controller.revertToAutomatic()) {
            XCTAssertEqual($0 as? FanControlError, .writeFailed(detail: "fan count unreadable"))
        }
        XCTAssertEqual(smc.value("F0Md"), 0)
        XCTAssertEqual(smc.value("F1Md"), 0)
    }

    /// SAFETY-1: an unreadable fan count must not turn a revert into a silent no-op.
    func test_revertToAutomatic_unreadableFanCountStillRevertsKnownFansAndReportsFailure() throws {
        let smc = FakeSMCConnection.appleSilicon(fans: [(1000, 4900, 1200), (1200, 6000, 2000)])
        let controller = controller(smc)
        _ = try controller.discoverFans()
        smc.set("F0Md", "ui8 ", 1)
        smc.set("F1Md", "ui8 ", 1)
        smc.readErrors["FNum"] = 0x85

        XCTAssertThrowsError(try controller.revertToAutomatic()) {
            XCTAssertEqual($0 as? FanControlError, .sensorUnavailable(detail: "SMC key FNum read error 133"))
        }
        XCTAssertEqual(smc.value("F0Md"), 0)
        XCTAssertEqual(smc.value("F1Md"), 0)
    }

    func test_revertToAutomatic_unlockKeyErrorIsReported() throws {
        let smc = FakeSMCConnection.appleSilicon(ftst: true)
        smc.infoErrors["Ftst"] = 0x85
        XCTAssertThrowsError(try controller(smc).revertToAutomatic()) {
            XCTAssertEqual($0 as? FanControlError, .sensorUnavailable(detail: "SMC key Ftst info error 133"))
        }
    }

    func test_revertToAutomatic_onFanlessMacIsANoOp() throws {
        let smc = FakeSMCConnection.appleSilicon(fans: [])
        smc.remove("FNum")
        try controller(smc).revertToAutomatic()
        XCTAssertTrue(smc.writeLog.isEmpty)
    }

    func test_detectsConflictingController_fromHardwareModeKeysOnEveryFan() {
        let smc = FakeSMCConnection.appleSilicon(fans: [(1000, 4900, 1200), (1200, 6000, 2000)], ftst: true)
        XCTAssertFalse(controller(smc).detectsConflictingController())
        smc.set("F1Md", "ui8 ", 1)
        XCTAssertTrue(controller(smc).detectsConflictingController(), "any fan, not just the first")
        smc.set("F1Md", "ui8 ", 0)
        smc.set("Ftst", "ui8 ", 1)
        XCTAssertTrue(controller(smc).detectsConflictingController())
        smc.transportError = .sensorUnavailable(detail: "down")
        XCTAssertFalse(controller(smc).detectsConflictingController(), "unknown is not reported as a conflict")
    }

    func test_smcErrorCodesAndTransportFailuresSurface() {
        let infoError = FakeSMCConnection.appleSilicon()
        infoError.infoErrors["FNum"] = 0x85
        XCTAssertThrowsError(try controller(infoError).discoverFans()) {
            XCTAssertEqual($0 as? FanControlError, .sensorUnavailable(detail: "SMC key FNum info error 133"))
        }
        let readError = FakeSMCConnection.appleSilicon()
        readError.readErrors["FNum"] = 0x85
        XCTAssertThrowsError(try controller(readError).discoverFans()) {
            XCTAssertEqual($0 as? FanControlError, .sensorUnavailable(detail: "SMC key FNum read error 133"))
        }
        let down = FakeSMCConnection.appleSilicon()
        down.transportError = .sensorUnavailable(detail: "SMC call failed")
        XCTAssertThrowsError(try controller(down).readTemperatures())
    }
}

/// Real AppleSMC, READ-ONLY. Never call setTargetRPM/revertToAutomatic on real hardware from tests.
@MainActor final class IOKitSMCConnectionTests: XCTestCase {
    private func requireAppleSMC() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        defer { IOObjectRelease(service) }
        try XCTSkipIf(service == IO_OBJECT_NULL, "coverage gate must run on real Apple Silicon hardware")
    }

    private func rawFanCount(_ connection: IOKitSMCConnection) throws -> Int {
        var info = SMCParamStruct()
        info.key = FourCC.code("FNum")
        info.data8 = SMCParamStruct.Command.readKeyInfo
        let keyInfo = try connection.call(info)
        guard keyInfo.result == 0 else { return 0 }
        var read = SMCParamStruct()
        read.key = FourCC.code("FNum")
        read.keyInfo.dataSize = keyInfo.keyInfo.dataSize
        read.data8 = SMCParamStruct.Command.readBytes
        return Int(try connection.call(read).payload(count: 1).first ?? 0)
    }

    func test_opensAppleSMCAndReadsTheKeyIndex() throws {
        try requireAppleSMC()
        var input = SMCParamStruct()
        input.key = FourCC.code("#KEY")
        input.data8 = SMCParamStruct.Command.readKeyInfo

        let output = try IOKitSMCConnection().call(input)

        XCTAssertEqual(output.result, 0)
        XCTAssertEqual(output.keyInfo.dataType, SMCDataType.ui32)
    }

    /// Tells "fanless" apart from "fan discovery broken", and keeps first display inside SC-001.
    func test_realControllerReadsThisMac() throws {
        try requireAppleSMC()
        let connection = try IOKitSMCConnection()
        let controller = IOKitSMCController(connection: connection)

        let fans = try controller.discoverFans()
        let started = Date()
        let readings = try controller.readTemperatures()

        XCTAssertEqual(fans.count, try rawFanCount(connection), "every fan the SMC reports is discovered")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "cold key discovery stays well inside SC-001's 2 s")
        XCTAssertTrue(readings.contains { $0.sourceLabel == TemperatureReading.cpuGroup }, "profiles need the CPU group on real hardware")
        XCTAssertTrue(readings.allSatisfy { (IOKitSMCController.floorCelsius...IOKitSMCController.ceilingCelsius).contains($0.celsius) })
    }

    /// S10: every connection is closed; opening repeatedly must not leak Mach ports.
    func test_connectionsAreClosedAndDoNotLeakPorts() throws {
        try requireAppleSMC()
        func portCount() -> Int {
            var names: mach_port_name_array_t?
            var types: mach_port_type_array_t?
            var nameCount: mach_msg_type_number_t = 0
            var typeCount: mach_msg_type_number_t = 0
            guard mach_port_names(mach_task_self_, &names, &nameCount, &types, &typeCount) == KERN_SUCCESS else { return -1 }
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: names), vm_size_t(nameCount) * vm_size_t(MemoryLayout<mach_port_name_t>.size))
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: types), vm_size_t(typeCount) * vm_size_t(MemoryLayout<mach_port_type_t>.size))
            return Int(nameCount)
        }
        _ = try IOKitSMCConnection()
        let before = portCount()
        for _ in 0..<100 { _ = try IOKitSMCConnection() }
        XCTAssertLessThan(portCount() - before, 20)
    }

    func test_missingServiceMeansUnsupportedHardware() {
        XCTAssertThrowsError(try IOKitSMCConnection(serviceName: "VentiladorNoSuchService")) {
            XCTAssertEqual($0 as? FanControlError, .unsupportedHardware)
        }
    }

    func test_serviceThatRefusesToOpenIsReported() {
        XCTAssertThrowsError(try IOKitSMCConnection(serviceName: "IOResources")) {
            XCTAssertTrue(describe($0).contains("cannot open IOResources"))
        }
    }

    func test_callOnADeadConnectionThrows() {
        XCTAssertThrowsError(try IOKitSMCConnection(connection: IO_OBJECT_NULL).call(SMCParamStruct())) {
            XCTAssertTrue(describe($0).contains("SMC call failed"))
        }
    }
}
