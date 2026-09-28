import Combine
import Foundation
import os

/// Append-only JSON Lines log: existing lines are never rewritten or deleted.
// ponytail: unbounded file + in-memory list, add rotation if logs ever reach MBs.
final class ControlEventLog: ObservableObject {
    @Published private(set) var entries: [ControlEventLogEntry]
    let fileURL: URL
    private let logger = Logger(subsystem: "com.ulm0.ventilador", category: "events")

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ventilador/events.jsonl")
    }

    init(fileURL: URL = ControlEventLog.defaultURL) {
        self.fileURL = fileURL
        entries = Self.load(fileURL)
    }

    func append(_ entry: ControlEventLogEntry) {
        entries.append(entry)
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            var line = try JSONEncoder().encode(entry)
            line.append(0x0A)
            if let handle = try? FileHandle(forUpdating: fileURL) {
                defer { try? handle.close() }
                let end = try handle.seekToEnd()
                if end > 0 {
                    try handle.seek(toOffset: end - 1)
                    // A crash mid-write leaves a torn last line; start on a fresh line so this entry survives.
                    if try handle.read(upToCount: 1) != Data([0x0A]) { line.insert(0x0A, at: 0) }
                    try handle.seekToEnd()
                }
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: fileURL)
            }
        } catch {
            logger.error("Could not persist control event: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Skips unreadable lines (e.g. a write torn by a crash) instead of dropping the whole log.
    static func load(_ url: URL) -> [ControlEventLogEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? JSONDecoder().decode(ControlEventLogEntry.self, from: Data($0)) }
    }
}
