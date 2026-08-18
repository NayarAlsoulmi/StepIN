//
//  StepINInteractivePreview.swift
//  StepIN
//
//  Full interactive Canvas preview for the complete StepIN journey.
//
//  HOW TO USE:
//  1. Open this file in Xcode.
//  2. Press Option+Cmd+Return to open Canvas.
//  3. Click the Live Preview button (▶) to enable interaction.
//
//  JOURNEY:
//  Splash → Onboarding → Create Account → Home → Start Interview
//  → Setup → AI Prep → Live Session → Analyzing → Results
//  → Tab navigation: Interviews / Goals / Profile
//
//  Everything runs through the real production screens and navigation.
//  The only preview-specific things here are:
//  - AppState starting with hasCompletedOnboarding = false, isAuthenticated = false
//  - PreviewData.container (in-memory, never touches production storage)
//

import SwiftUI
import SwiftData

// MARK: - Wrapper

/// Thin shell that injects preview-safe dependencies into the real RootView.
/// No production UI, navigation, or business logic is duplicated here.
private struct StepINInteractivePreview: View {
    @State private var appState = AppState(
        hasProfile: false,
        hasCompletedOnboarding: false,
        isAuthenticated: false,
        currentUser: nil
    )

    var body: some View {
        RootView()
            .environment(appState)
            .tint(StepINColor.primary)
    }
}

// MARK: - Preview

#Preview("StepIN — Full Interactive Journey") {
    StepINInteractivePreview()
        .modelContainer(PreviewData.container)
}
