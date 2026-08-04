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
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: StepINRadius.large, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: StepINRadius.large, style: .continuous)
                    .stroke(StepINColor.border, lineWidth: 1)
            )
            .stepINShadow(.subtle)
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
        StepINColor.background.ignoresSafeArea()
    }
}
