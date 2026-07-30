import Foundation

/// Imperial display units (docs/03): the app SHOWS miles and feet
/// everywhere, while every model, API payload, and rule stays metric —
/// meters in, formatted strings out.
public enum UnitFormat {
    public static let metersPerMile = 1_609.344
    public static let feetPerMeter = 3.28084

    public static func miles(fromMeters m: Double) -> Double {
        m / metersPerMile
    }

    /// Number only ("3.24") — for layouts that place the "mi" label
    /// separately, like the run card's hero figure.
    public static func milesText(fromMeters m: Double, decimals: Int = 2) -> String {
        String(format: "%.\(decimals)f", miles(fromMeters: m))
    }

    /// "3.2 mi"
    public static func milesLabel(fromMeters m: Double, decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f mi", miles(fromMeters: m))
    }

    public static func feet(fromMeters m: Double) -> Int {
        Int((m * feetPerMeter).rounded())
    }

    /// Walking-scale distances: feet up close, miles once feet get silly.
    /// "240 ft" below ~500 ft, else "0.5 mi".
    public static func shortDistance(fromMeters m: Double) -> String {
        m < 152.4 ? "\(feet(fromMeters: m)) ft" : milesLabel(fromMeters: m)
    }

    /// Pace stays seconds-per-km in every model and API; only the display
    /// stretches it to the mile.
    public static func paceSecPerMile(fromSecPerKm p: Int) -> Int {
        Int((Double(p) * metersPerMile / 1_000).rounded())
    }
}
