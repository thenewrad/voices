import SwiftUI

// MARK: - City Night palette (LA nightscape)
// Cool deep blues for backgrounds and atmosphere
// Warm amber accent retained from canyon
// Red action color retained for record/like

enum AppTheme {

    // MARK: Base colors

    static let canvasBlack = Color(hex: "050810") // page background — deep night sky
    static let cardDark    = Color(hex: "0D2340") // card / row background — midnight blue

    static let rust     = Color(hex: "C4622D")  // primary accent — retained from canyon
    static let gold     = Color(hex: "C8A84E")  // secondary accent — city amber glow
    static let dusk     = Color(hex: "0D2340")  // dark header: midnight blue
    static let lavender = Color(hex: "1B4A7A")  // dark header: city blue
    static let slate    = Color(hex: "5BA8D4")  // dark header: searchlight blue
    static let ember    = Color(hex: "D4553A")  // record: warm red-orange (retained)
    static let sand     = Color(hex: "F5EAC0")  // record: warm white city glow
    static let skyTint  = Color(hex: "5BA8D4")  // background tint — searchlight blue

    // Legacy aliases
    static var purple:  Color { dusk }
    static var skyBlue: Color { slate }
    static var violet:  Color { lavender }

    // MARK: Gradients

    /// Main interactive gradient — waveform bars, active states, accent buttons.
    /// City blue → searchlight.
    static let gradient = LinearGradient(
        colors: [rust, gold],
        startPoint: .leading,
        endPoint: .trailing
    )

    /// Mini player bar background.
    static let gbar = LinearGradient(
        colors: [rust, gold],
        startPoint: .leading,
        endPoint: .trailing
    )

    /// Full-screen player (NowPlayingView) — deep night sky atmosphere.
    static let gplayer = LinearGradient(
        colors: [Color(hex: "050810"), Color(hex: "0D2340"), Color(hex: "1B4A7A")],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Local / Drive Mode bar and map accent.
    static let glocal = LinearGradient(
        colors: [Color(hex: "1B4A7A"), Color(hex: "5BA8D4")],
        startPoint: .leading,
        endPoint: .trailing
    )

    /// Thread view header and accent bar.
    static let gthread = LinearGradient(
        colors: [Color(hex: "050810"), Color(hex: "0D2340")],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Record button — ember red to warm white.
    static let grecord = LinearGradient(
        colors: [ember, sand],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Dark header gradient — onboarding / splash / profile header overlays.
    static let header = LinearGradient(
        colors: [Color(hex: "050810"), Color(hex: "0D2340"), Color(hex: "1B4A7A")],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

// MARK: - Hex init

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 6:
            (r, g, b) = ((int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default:
            (r, g, b) = (0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255
        )
    }
}
