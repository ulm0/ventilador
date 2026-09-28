import Foundation

func clamp(target: Int, to fan: Fan) -> Int {
    min(max(target, fan.minSafeRPM), fan.maxSafeRPM)
}
