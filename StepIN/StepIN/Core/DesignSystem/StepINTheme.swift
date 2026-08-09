//
//  StepINTheme.swift
//  StepIN
//
//  Centralized design tokens: colors, spacing, corner radii, shadows, motion.
//  Do not hard-code these values in Views — always reference StepINTheme.
//

import SwiftUI

// MARK: - Color from hex

extension Color {
    /// Create a Color from a 24-bit RGB hex value, e.g. 0x806AF4.
    init(hex: UInt, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }

    /// A color that resolves differently in Light and Dark appearances.
    static func stepINDynamic(light: UInt, dark: UInt) -> Color {
        Color(uiColor: UIColor { trait in
            let value = trait.userInterfaceStyle == .dark ? dark : light
            let r = CGFloat((value >> 16) & 0xFF) / 255.0
            let g = CGFloat((value >> 8) & 0xFF) / 255.0
            let b = CGFloat(value & 0xFF) / 255.0
            return UIColor(red: r, green: g, blue: b, alpha: 1)
        })
    }
}

// MARK: - Semantic color tokens

enum StepINColor {
    // Backgrounds & surfaces
    static let background          = Color.stepINDynamic(light: 0xFCFCFE, dark: 0x0E0E12)
    static let backgroundSecondary = Color.stepINDynamic(light: 0xF4F4F8, dark: 0x16161C)
    static let surface             = Color.stepINDynamic(light: 0xFFFFFF, dark: 0x1C1C24)
    static let surfaceElevated     = Color.stepINDynamic(light: 0xFFFFFF, dark: 0x24242E)

    // Brand purple
    static let primary      = Color.stepINDynamic(light: 0x806AF4, dark: 0x9280F7)
    static let primaryDark  = Color.stepINDynamic(light: 0x5E48D0, dark: 0x6E58E0)
    static let primaryLight = Color.stepINDynamic(light: 0xA394F7, dark: 0xB3A6FA)
    static let primarySoft  = Color.stepINDynamic(light: 0xEEE9FE, dark: 0x2A2542)
    static let accent       = primary
    /// Soft cyan used only by the robot's listening pulse.
    static let listeningCyan = Color.stepINDynamic(light: 0x4FD4E8, dark: 0x5CDEF0)

    // Text
    static let textPrimary   = Color.stepINDynamic(light: 0x1E1E24, dark: 0xF2F2F7)
    static let textSecondary = Color.stepINDynamic(light: 0x5B5B66, dark: 0xB4B4C0)
    static let textTertiary  = Color.stepINDynamic(light: 0x9A9AA6, dark: 0x7C7C88)
    static let onPrimary     = Color.white

    // Lines
    static let border  = Color.stepINDynamic(light: 0xE6E6EE, dark: 0x33333E)
    static let divider = Color.stepINDynamic(light: 0xEDEDF3, dark: 0x2A2A34)

    // Status (secondary palette from Figma)
    static let success = Color.stepINDynamic(light: 0x43A836, dark: 0x57C24A)
    static let gold    = Color.stepINDynamic(light: 0xF5C13B, dark: 0xF7CC5C)
    static let warning = gold
    static let error   = Color.stepINDynamic(light: 0xE7605A, dark: 0xEE756F)
    static let info    = Color.stepINDynamic(light: 0x5573F0, dark: 0x6E88F3)

    static let shadow = Color.black.opacity(0.08)
}

// MARK: - Gradients

enum StepINGradient {
    /// Soft purple-led hero gradient. Never neon.
    static let hero = LinearGradient(
        colors: [
            Color.stepINDynamic(light: 0x8B76F6, dark: 0x6E58E0),
            Color.stepINDynamic(light: 0xA98FF8, dark: 0x8B76F6)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Subtle glow behind the robot.
    static let robotGlow = RadialGradient(
        colors: [StepINColor.primary.opacity(0.35), StepINColor.primary.opacity(0)],
        center: .center,
        startRadius: 4,
        endRadius: 160
    )
}

// MARK: - Spacing scale

enum StepINSpacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat  = 8
    static let sm: CGFloat  = 12
    static let md: CGFloat  = 16
    static let lg: CGFloat  = 20
    static let xl: CGFloat  = 24
    static let xxl: CGFloat = 32
    static let xxxl: CGFloat = 40
    static let huge: CGFloat = 48
    static let giant: CGFloat = 64

    /// Default horizontal screen padding.
    static let screenH: CGFloat = 20
    /// Default spacing between sections.
    static let section: CGFloat = 28
}

// MARK: - Corner radii

enum StepINRadius {
    static let small: CGFloat  = 12
    static let medium: CGFloat = 16
    static let large: CGFloat  = 22
    static let hero: CGFloat   = 28
}

// MARK: - Shadows

struct StepINShadow {
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat

    static let card = StepINShadow(color: StepINColor.shadow, radius: 18, x: 0, y: 8)
    static let subtle = StepINShadow(color: StepINColor.shadow, radius: 8, x: 0, y: 3)
}

extension View {
    func stepINShadow(_ shadow: StepINShadow = .card) -> some View {
        self.shadow(color: shadow.color, radius: shadow.radius, x: shadow.x, y: shadow.y)
    }
}

// MARK: - Motion

enum StepINMotion {
    static let fast: Double = 0.18
    static let standard: Double = 0.3
    static let slow: Double = 0.6

    static let springStandard = Animation.spring(response: 0.4, dampingFraction: 0.82)
    static let springSnappy = Animation.spring(response: 0.28, dampingFraction: 0.8)
    static let fade = Animation.easeInOut(duration: standard)
}

//glass Card

extension View {

    func glassCard() -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: 28)
                    .fill(.white.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 28)
                    .stroke(.white.opacity(0.8), lineWidth: 1)
            )
            .shadow(
                color: .black.opacity(0.05),
                radius: 24,
                y: 12
            )
    }
}
