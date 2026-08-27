import SwiftUI

extension Color {
    /// One parser for every frozen Ability reference shown by the macOS app.
    /// Active packages have already passed tint validation; the fallback keeps
    /// persisted or hand-built diagnostic references readable.
    static func maryAbilityTint(
        _ hex: String,
        fallback: Color = .maryGold
    ) -> Color {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard value.count == 6, let rgb = UInt64(value, radix: 16) else {
            return fallback
        }
        return Color(
            red: Double((rgb >> 16) & 0xff) / 255,
            green: Double((rgb >> 8) & 0xff) / 255,
            blue: Double(rgb & 0xff) / 255)
    }
}
