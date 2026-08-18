//
//  RootView.swift
//  StepIN
//
//  Launch flow: Splash → Onboarding → Authentication → Tabs.
//

import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(AppState.self) private var appState
    @State private var splashFinished = false

    var body: some View {
        Group {
            if !splashFinished {
                SplashView {
                    withAnimation(StepINMotion.fade) { splashFinished = true }
                }
            } else if !appState.hasCompletedOnboarding {
                OnboardingView {
                    withAnimation(StepINMotion.fade) { appState.completeOnboarding() }
                }
            } else if !appState.isAuthenticated {
                AuthenticationView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                RootTabView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await appState.validateRestoredSessionIfNeeded()
        }
    }
}

#Preview {
    RootView()
        .environment(AppState(hasProfile: true, hasCompletedOnboarding: true, isAuthenticated: true))
        .modelContainer(PreviewData.container)
}
