//
//  RootView.swift
//  StepIN
//
//  Launch flow: Splash → (Onboarding → Create Profile, first run) → Tabs.
//

import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(AppState.self) private var appState
    @State private var splashFinished = false

    var body: some View {
        ZStack {
            if !splashFinished {
                SplashView {
                    withAnimation(StepINMotion.fade) { splashFinished = true }
                }
                .transition(.opacity)
            } else if !appState.hasCompletedOnboarding {
                OnboardingView {
                    withAnimation(StepINMotion.fade) { appState.completeOnboarding() }
                }
                .transition(.opacity)
            } else if !appState.hasProfile {
                CreateProfileView {
                    withAnimation(StepINMotion.fade) { appState.hasProfile = true }
                }
                transition(.opacity)
            } else {
                RootTabView()
                    .transition(.opacity)
            }
        }
    }
}

#Preview {
    RootView()
        .environment(AppState(hasProfile: true))
        .modelContainer(PreviewData.container)
}
