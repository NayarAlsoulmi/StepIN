//
//  AppState.swift
//  StepIN
//
//  High-level app state. Holds only cross-cutting concerns — no
//  feature-specific logic lives here.
//

import SwiftUI

enum StepINNavigationBridge {
    nonisolated static let startInterviewRequestIDKey = "stepin.pendingStartInterviewRequestID"
    nonisolated static let startInterviewNotification = Notification.Name("stepin.startInterviewRequested")

    nonisolated static func requestStartInterview() {
        UserDefaults.standard.set(UUID().uuidString, forKey: startInterviewRequestIDKey)
        NotificationCenter.default.post(name: startInterviewNotification, object: nil)
    }

    nonisolated static func clearStartInterviewRequest() {
        UserDefaults.standard.removeObject(forKey: startInterviewRequestIDKey)
    }
}

/// The primary tabs of the application.
enum StepINTab: Hashable, CaseIterable {
    case home
    case interviews
    case goals

    var title: String {
        switch self {
        case .home: "Home"
        case .interviews: "Interviews"
        case .goals: "Goals"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house.fill"
        case .interviews: "bubble.left.and.bubble.right.fill"
        case .goals: "checkmark.circle.fill"
        }
    }
}

@Observable
final class AppState {
    /// Whether first-run onboarding has been completed.
    var hasCompletedOnboarding: Bool
    /// Whether a local profile exists.
    var hasProfile: Bool
    /// Currently selected tab.
    var selectedTab: StepINTab = .home
    /// Global connectivity flag (updated by the network monitor in a later phase).
    var isConnected: Bool = true

    private let onboardingKey = "stepin.hasCompletedOnboarding"

    init(hasProfile: Bool = false) {
        self.hasCompletedOnboarding = UserDefaults.standard.bool(forKey: onboardingKey)
        self.hasProfile = hasProfile
    }

    /// Preview-only: bypasses UserDefaults so Canvas always starts from a known state.
    /// Production code uses the single-argument init above.
    init(hasProfile: Bool, hasCompletedOnboarding: Bool) {
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.hasProfile = hasProfile
    }

    func completeOnboarding() {
        hasCompletedOnboarding = true
        UserDefaults.standard.set(true, forKey: onboardingKey)
    }
}
