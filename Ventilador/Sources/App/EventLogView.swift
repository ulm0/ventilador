import SwiftUI

/// The whole log, newest first, scrollable — every entry stays viewable (FR-010, SC-006).
struct EventLogView: View {
    @ObservedObject var log: ControlEventLog

    var visibleLines: [String] { Self.lines(for: log.entries) }
    var showsEmptyState: Bool { log.entries.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Events").font(.headline)
            if showsEmptyState {
                Text("No events yet.").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(visibleLines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption).lineLimit(2)
                    }
                }
            }
            .frame(maxHeight: 140)
        }
    }

    static func lines(for entries: [ControlEventLogEntry]) -> [String] {
        entries.reversed().map { line(for: $0) }
    }

    static func line(for entry: ControlEventLogEntry) -> String {
        let time = entry.timestamp.formatted(date: .abbreviated, time: .standard)
        guard let fanID = entry.fanID, let rpm = entry.targetRPM else { return "\(time) \(entry.detail)" }
        return "\(time) \(entry.detail) [fan \(fanID): \(rpm) RPM]"
    }
}
