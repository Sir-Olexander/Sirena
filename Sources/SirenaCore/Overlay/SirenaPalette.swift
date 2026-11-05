import SwiftUI

/// Colors for the pill, taken from the original logo drawing: silvery-white line art on near-black.
/// Each state keeps a faint tint of its own so it can be told apart at a glance.
enum SirenaPalette {
    /// The logo's background.
    static let ink = Color(red: 0.008, green: 0.008, blue: 0.008)
    /// The logo's line art: a cool moonlight white. Awake and listening.
    static let moonlight = Color(red: 0.90, green: 0.93, blue: 0.97)
    /// Muted silver: waiting for "Hey Sirena", Cancel, inactive marks.
    static let silver = Color(white: 0.62)
    /// Warm pearl: dictating.
    static let pearl = Color(red: 0.95, green: 0.84, blue: 0.64)
    /// Silver lilac: reading aloud.
    static let lilac = Color(red: 0.80, green: 0.77, blue: 0.97)

    /// Pill fills: the logo's black, barely tinted toward the state's accent.
    static let inkFill = ink.opacity(0.86)
    static let pearlFill = Color(red: 0.10, green: 0.08, blue: 0.05).opacity(0.92)
    static let lilacFill = Color(red: 0.07, green: 0.06, blue: 0.11).opacity(0.92)
    static let errorFill = Color(red: 0.30, green: 0.07, blue: 0.08).opacity(0.92)
}
