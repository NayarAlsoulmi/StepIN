//
//  StepINComponents.swift
//  StepIN
//
//  Reusable design-system components. Presentation only — no business logic.
//

import SwiftUI

// MARK: - Primary Button

struct StepINPrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    var isLoading: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: {
            guard isEnabled && !isLoading else { return }
            action()
        }) {
            HStack(spacing: StepINSpacing.xs) {
                if isLoading {
                    ProgressView()
                        .tint(StepINColor.onPrimary)
                } else {
                    if let systemImage {
                        Image(systemName: systemImage)
                    }
                    Text(title)
                }
            }
            .font(StepINFont.button)
            .foregroundColor(StepINColor.onPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(StepINColor.primary)
            .clipShape(RoundedRectangle(cornerRadius: StepINRadius.medium, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(StepINPressStyle())
        .disabled(!isEnabled || isLoading)
        .accessibilityLabel(Text(title))
    }
}

// MARK: - Secondary Button

struct StepINSecondaryButton: View {
    let title: String
    var systemImage: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: StepINSpacing.xs) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(StepINFont.button)
            .foregroundColor(StepINColor.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(StepINColor.primarySoft)
            .clipShape(RoundedRectangle(cornerRadius: StepINRadius.medium, style: .continuous))
        }
        .buttonStyle(StepINPressStyle())
    }
}

// MARK: - Destructive Button

struct StepINDestructiveButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) {
            Text(title)
                .font(StepINFont.button)
                .foregroundColor(StepINColor.error)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(StepINColor.error.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: StepINRadius.medium, style: .continuous))
        }
        .buttonStyle(StepINPressStyle())
    }
}

/// Subtle press-down scale used by all StepIN buttons.
struct StepINPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(StepINMotion.springSnappy, value: configuration.isPressed)
    }
}

// MARK: - Card

struct StepINCard<Content: View>: View {
    var padding: CGFloat = StepINSpacing.md
    var background: Color = StepINColor.surface
    var tintOpacity: Double = 0.12
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: StepINRadius.large, style: .continuous))
            .background(cardBackground)
    }

    @ViewBuilder
    private var cardBackground: some View {
        if #available(iOS 26.0, *) {
            RoundedRectangle(cornerRadius: StepINRadius.large, style: .continuous)
                .fill(background.opacity(tintOpacity))
                .glassEffect(
                    .regular.tint(Color.white.opacity(0.01)),
                    in: RoundedRectangle(cornerRadius: StepINRadius.large, style: .continuous)
                )
        } else {
            RoundedRectangle(cornerRadius: StepINRadius.large, style: .continuous)
                .fill(.white.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: StepINRadius.large, style: .continuous)
                        .stroke(.white.opacity(0.8), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.05), radius: 24, y: 12)
        }
    }
}

// MARK: - Section Header

struct StepINSectionHeader: View {
    let title: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack {
            Text(title)
                .font(StepINFont.h3)
                .foregroundColor(StepINColor.textPrimary)
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(StepINFont.body3)
                    .foregroundColor(StepINColor.primary)
            }
        }
    }
}

// MARK: - Empty State

struct StepINEmptyState: View {
    var robotState: RobotState = .idle
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: StepINSpacing.md) {
            RobotView(state: robotState, presentation: .emptyState)
            Text(title)
                .font(StepINFont.h3)
                .foregroundColor(StepINColor.textPrimary)
                .multilineTextAlignment(.center)
            Text(message)
                .font(StepINFont.bodyRegular)
                .foregroundColor(StepINColor.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                StepINPrimaryButton(title: actionTitle, action: action)
                    .padding(.top, StepINSpacing.xs)
                    .frame(maxWidth: 280)
            }
        }
        .padding(StepINSpacing.xl)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Loading View

struct StepINLoadingView: View {
    let message: String

    var body: some View {
        VStack(spacing: StepINSpacing.md) {
            RobotView(state: .thinking, presentation: .loading)
            Text(message)
                .font(StepINFont.body1)
                .foregroundColor(StepINColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(StepINSpacing.xl)
    }
}

// MARK: - Screen background


struct StepINScreenBackground: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(hex: 0xFDFDFE)
                    .ignoresSafeArea()

                let width = proxy.size.width
                let height = proxy.size.height
                let glowWidth = max(width * 0.86, 346)
                let glowHeight = max(height * 0.23, 204)

                // Top Left
                Ellipse()
                    .fill(Color(hex: 0xF6E3D8))
                    .frame(width: glowWidth, height: glowHeight)
                    .blur(radius: 80)
                    .position(x: width * 0.31, y: height * 0.10)

                // Top Right
                Ellipse()
                    .fill(Color(hex: 0xE8E3E9))
                    .frame(width: glowWidth, height: glowHeight)
                    .blur(radius: 80)
                    .position(x: width * 0.83, y: height * 0.10)

                // Center
                Ellipse()
                    .fill(Color(hex: 0xE3D7E9))
                    .frame(width: glowWidth, height: glowHeight)
                    .blur(radius: 105)
                    .position(x: width * 0.50, y: height * 0.50)

                // Bottom Right
                Ellipse()
                    .fill(Color(hex: 0xF4D6E8))
                    .opacity(0.5)
                    .frame(width: glowWidth, height: glowHeight)
                    .blur(radius: 90)
                    .position(x: width * 0.92, y: height * 0.88)

                // Bottom Left
                Ellipse()
                    .fill(Color(hex: 0xD9C7F8))
                    .opacity(0.55)
                    .frame(width: glowWidth, height: glowHeight)
                    .blur(radius: 90)
                    .position(x: width * 0.26, y: height * 0.85)
            }
            .ignoresSafeArea()
        }
    }
}

struct Background: View {
    var body: some View {
        ZStack {
            Ellipse()
                .fill(Color(hex: 0xF6E3D8))
                .frame(width: 346, height: 204)
                .blur(radius: 80)
                .position(x: -47 + 173, y: -16 + 102)

            // Top Right
            Ellipse()
                .fill(Color(hex: 0xE8E3E9))
                .frame(width: 346, height: 204)
                .blur(radius: 80)
                .position(x: 162 + 173, y: -19 + 102)

            // Center
            Ellipse()
                .fill(Color(hex: 0xE3D7E9))
                .frame(width: 346, height: 204)
                .blur(radius: 105)
                .position(x: 28 + 173, y: 335 + 102)

            // Bottom Right
            Ellipse()
                .fill(Color(hex: 0xF4D6E8))
                .opacity(0.5)
                .frame(width: 346, height: 204)
                .blur(radius: 90)
                .position(x: 195 + 173, y: 670 + 102)

            // Bottom Left
            Ellipse()
                .fill(Color(hex: 0xD9C7F8))
                .opacity(0.55)
                .frame(width: 346, height: 204)
                .blur(radius: 90)
                .position(x: -68 + 173, y: 636 + 102)
        }
        .frame(width: 402, height: 874)
    }
}
