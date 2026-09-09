import Foundation

enum Formatting {
    /// "37.8 °C / 100.0 °F"
    static func temperature(_ celsius: Double) -> String {
        String(format: "%.1f °C / %.1f °F", celsius, celsius * 9 / 5 + 32)
    }
}
