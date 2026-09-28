import Foundation

struct FanProfile: Identifiable, Equatable {
    struct Point: Equatable {
        let celsius: Double
        let rpmFraction: Double
    }

    let id: String
    let name: String
    let curve: [Point]

    /// Rejects curves that could ask a fan to slow down as it gets hotter.
    init?(id: String, name: String, curve: [Point]) {
        guard curve.count >= 2,
              curve.allSatisfy({ (0...1).contains($0.rpmFraction) }),
              zip(curve, curve.dropFirst()).allSatisfy({ $0.celsius < $1.celsius && $0.rpmFraction <= $1.rpmFraction })
        else { return nil }
        self.id = id
        self.name = name
        self.curve = curve
    }

    /// What the curve does, as percentages of each fan's safe speed range.
    var summary: String {
        let first = curve[0], last = curve[curve.count - 1]
        return "Ramps from \(Int(first.rpmFraction * 100))% at \(Int(first.celsius)) °C to \(Int(last.rpmFraction * 100))% at \(Int(last.celsius)) °C"
    }

    /// Fraction in [0, 1], linear between control points, flat beyond the ends.
    func evaluate(atCelsius celsius: Double) -> Double {
        guard let upper = curve.firstIndex(where: { $0.celsius >= celsius }) else { return curve[curve.count - 1].rpmFraction }
        guard upper > 0 else { return curve[0].rpmFraction }
        let low = curve[upper - 1], high = curve[upper]
        return low.rpmFraction + (high.rpmFraction - low.rpmFraction) * (celsius - low.celsius) / (high.celsius - low.celsius)
    }

    func targetRPM(for fan: Fan, atCelsius celsius: Double) -> Int {
        let span = Double(fan.maxSafeRPM - fan.minSafeRPM)
        return fan.minSafeRPM + Int((evaluate(atCelsius: celsius) * span).rounded())
    }
}
