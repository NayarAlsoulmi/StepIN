//
//  StepINTypography.swift
//  StepIN
//
//  SF Pro type scale mirroring the Figma design system.
//  SwiftUI system fonts scale with Dynamic Type.
//

import SwiftUI

enum StepINFont {
    // Headings
    static let h1 = Font.system(size: 24, weight: .bold)      // Screen / hero titles
    static let h2 = Font.system(size: 22, weight: .bold)
    static let h3 = Font.system(size: 20, weight: .bold)      // Section titles
    static let h4 = Font.system(size: 16, weight: .bold)      // Card titles
    static let h5 = Font.system(size: 14, weight: .bold)

    // Body (semibold-led, per Figma)
    static let body1 = Font.system(size: 16, weight: .semibold)
    static let body2 = Font.system(size: 15, weight: .semibold)
    static let body3 = Font.system(size: 14, weight: .semibold)
    static let body4 = Font.system(size: 13, weight: .semibold)
    static let body5 = Font.system(size: 12, weight: .semibold)

    // Regular body for longer copy
    static let bodyRegular = Font.system(size: 16, weight: .regular)
    static let caption = Font.system(size: 12, weight: .regular)

    static let nav = Font.system(size: 16, weight: .bold)
    static let button = Font.system(size: 17, weight: .semibold)
}

extension Text {
    /// Convenience: apply a font token and a semantic color in one call.
    func stepINStyle(_ font: Font, color: Color = StepINColor.textPrimary) -> Text {
        self.font(font).foregroundColor(color)
    }
}
