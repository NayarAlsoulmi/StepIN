//
//  StepINProfileAvatar.swift
//  StepIN
//
//  Shared circular avatar used for profile photos with initials fallback.
//

import SwiftUI
import UIKit

struct StepINProfileAvatar: View {
    let image: UIImage?
    let initials: String
    var size: CGFloat = 66
    var initialsFont: Font = .system(.headline, design: .rounded, weight: .semibold)

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .allowsHitTesting(false)
            } else {
                Circle()
                    .fill(StepINColor.primarySoft)
                    .allowsHitTesting(false)

                Text(initials)
                    .font(initialsFont)
                    .foregroundStyle(StepINColor.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(size * 0.12)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size, height: size)
        .overlay(
            Circle()
                .strokeBorder(Color.white.opacity(0.92), lineWidth: 1)
                .allowsHitTesting(false)
        )
        .shadow(color: StepINColor.shadow.opacity(0.45), radius: size * 0.11, x: 0, y: size * 0.05)
        .accessibilityHidden(true)
    }
}
