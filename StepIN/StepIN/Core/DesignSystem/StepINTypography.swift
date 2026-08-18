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
    static let h1 = Font.system(size: 24, weight: .bold, design: .rounded)      // Screen / hero titles
    static let h2 = Font.system(size: 22, weight: .bold, design: .rounded)
    static let h3 = Font.system(size: 20, weight: .bold, design: .rounded)      // Section titles
    static let h4 = Font.system(size: 16, weight: .bold, design: .rounded)      // Card titles
    static let h5 = Font.system(size: 14, weight: .bold, design: .rounded)

    // Body (semibold-led, per Figma)
    static let body1 = Font.system(size: 16, weight: .semibold, design: .rounded)
    static let body2 = Font.system(size: 15, weight: .semibold, design: .rounded)
    static let body3 = Font.system(size: 14, weight: .semibold, design: .rounded)
    static let body4 = Font.system(size: 13, weight: .semibold, design: .rounded)
    static let body5 = Font.system(size: 12, weight: .semibold, design: .rounded)

    // Regular body for longer copy
    static let bodyRegular = Font.system(size: 16, weight: .regular, design: .rounded)
    static let caption = Font.system(size: 12, weight: .regular, design: .rounded)

    static let nav = Font.system(size: 16, weight: .bold, design: .rounded)
    static let button = Font.system(size: 17, weight: .semibold, design: .rounded)
}

extension Text {
    /// Convenience: apply a font token and a semantic color in one call.
    func stepINStyle(_ font: Font, color: Color = StepINColor.textPrimary) -> Text {
        self.font(font).foregroundColor(color)
    }
}
