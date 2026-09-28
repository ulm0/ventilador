import Foundation

/// Matches the SC-003 revert window so "too old to trust" and "unreachable" fail closed together.
let stalenessThreshold: TimeInterval = 5

func isStale(readAt: Date, asOf now: Date, threshold: TimeInterval = stalenessThreshold) -> Bool {
    now.timeIntervalSince(readAt) > threshold
}
