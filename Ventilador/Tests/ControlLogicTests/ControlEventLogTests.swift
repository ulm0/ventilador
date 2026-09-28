@testable import Ventilador
import XCTest

@MainActor final class ControlEventLogTests: XCTestCase {
    private func entry(_ detail: String, fan: Fan.ID? = nil, rpm: Int? = nil) -> ControlEventLogEntry {
        ControlEventLogEntry(timestamp: Date(timeIntervalSinceReferenceDate: 12_345.678), kind: .modeChanged, fanID: fan, targetRPM: rpm, detail: detail)
    }

    // T048
    func test_controlEventLog_isAppendOnly_neverMutatesOrDeletesExistingEntries() throws {
        let url = temporaryLogURL()
        let log = ControlEventLog(fileURL: url)
        log.append(entry("first"))
        log.append(entry("second"))
        let before = try Data(contentsOf: url)

        log.append(entry("third"))

        let after = try Data(contentsOf: url)
        XCTAssertEqual(after.prefix(before.count), before, "earlier bytes untouched")
        XCTAssertGreaterThan(after.count, before.count)
        XCTAssertEqual(ControlEventLog.load(url).map(\.detail), ["first", "second", "third"])
    }

    // T049 / Constitution Principle IV
    func test_controlEventLog_populatesFanIDAndTargetRPM_forFanSpecificEvents() {
        let url = temporaryLogURL()
        ControlEventLog(fileURL: url).append(entry("clamped", fan: "1", rpm: 4900))

        let reloaded = ControlEventLog.load(url)

        XCTAssertEqual(reloaded.first?.fanID, "1")
        XCTAssertEqual(reloaded.first?.targetRPM, 4900)
        XCTAssertEqual(reloaded.first?.timestamp, Date(timeIntervalSinceReferenceDate: 12_345.678), "timestamps round-trip exactly")
    }

    /// A crash mid-write leaves a torn last line with no newline; the next entry must not be glued onto it.
    func test_controlEventLog_tornTailNeverSwallowsTheNextEntry() throws {
        let url = temporaryLogURL()
        let log = ControlEventLog(fileURL: url)
        log.append(entry("kept 1"))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"timestamp\": 1, \"kind\": \"modeCh".utf8))
        try handle.close()

        log.append(entry("kept 2"))
        log.append(entry("kept 3"))

        XCTAssertEqual(ControlEventLog(fileURL: url).entries.map(\.detail), ["kept 1", "kept 2", "kept 3"])
    }

    func test_controlEventLog_healthyLogHasExactlyOneLinePerEntry() throws {
        let url = temporaryLogURL()
        let log = ControlEventLog(fileURL: url)
        for index in 0..<5 { log.append(entry("entry \(index)")) }

        let bytes = try Data(contentsOf: url)

        XCTAssertEqual(bytes.filter { $0 == 0x0A }.count, 5)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("\n\n"), "no blank lines from over-eager repair")
        XCTAssertEqual(bytes.last, 0x0A)
    }

    func test_controlEventLog_repairsATearAfterTheVeryFirstByte() throws {
        let url = temporaryLogURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{".utf8).write(to: url)

        ControlEventLog(fileURL: url).append(entry("survives"))

        XCTAssertEqual(ControlEventLog.load(url).map(\.detail), ["survives"])
    }

    func test_eventLogView_showsEveryEntryNewestFirstAndAnEmptyState() {
        let log = ControlEventLog(fileURL: temporaryLogURL())
        XCTAssertTrue(EventLogView(log: log).showsEmptyState)
        XCTAssertEqual(EventLogView(log: log).visibleLines, [])

        for index in 0..<12 { log.append(entry("entry \(index)")) }

        let view = EventLogView(log: log)
        XCTAssertFalse(view.showsEmptyState)
        XCTAssertEqual(view.visibleLines.count, 12)
        XCTAssertTrue(view.visibleLines.first!.hasSuffix("entry 11"))
        XCTAssertTrue(view.visibleLines.last!.hasSuffix("entry 0"))
    }

    func test_controlEventLog_oldEntriesWithoutModeStillLoad() throws {
        let url = temporaryLogURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"timestamp\":1,\"kind\":\"modeChanged\",\"detail\":\"legacy\"}\n".utf8).write(to: url)
        let entries = ControlEventLog.load(url)
        XCTAssertEqual(entries.map(\.detail), ["legacy"])
        XCTAssertNil(entries.first?.mode)
    }

    func test_controlEventLog_startsEmptyWithoutAFile() {
        XCTAssertTrue(ControlEventLog(fileURL: temporaryLogURL()).entries.isEmpty)
    }

    func test_controlEventLog_keepsEntriesInMemoryWhenDiskWriteFails() throws {
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("VentiladorTests-blocker-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: blocker)
        let log = ControlEventLog(fileURL: blocker.appendingPathComponent("events.jsonl"))

        log.append(entry("still visible"))

        XCTAssertEqual(log.entries.map(\.detail), ["still visible"])
    }

    func test_controlEventLog_defaultLocationIsApplicationSupport() {
        XCTAssertTrue(ControlEventLog.defaultURL.path.hasSuffix("Library/Application Support/Ventilador/events.jsonl"))
    }
}
