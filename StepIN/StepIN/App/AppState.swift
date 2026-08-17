//
//  AppState.swift
//  StepIN
//
//  High-level app state. Holds only cross-cutting concerns — no
//  feature-specific logic lives here.
//

import SwiftUI

/// Bridge used by App Intents to request navigation in the running app.
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
    /// Whether the app currently has a persisted authenticated session.
    private(set) var isAuthenticated: Bool
    /// The authenticated account for the current session.
    private(set) var currentUser: AuthenticatedUser?
    /// Currently selected tab.
    var selectedTab: StepINTab = .home
    /// Global connectivity flag (updated by the network monitor in a later phase).
    var isConnected: Bool = true

    private let onboardingKey = "stepin.hasCompletedOnboarding"
    private let authenticationService: AuthenticationServiceProtocol
    private let shouldValidateRestoredSession: Bool

    var authenticationProvider: AuthenticationProvider? {
        currentUser?.provider
    }

    init(
        hasProfile: Bool = false,
        authenticationService: AuthenticationServiceProtocol = StepINAuthenticationService()
    ) {
        // Read onboarding state first using a local constant to avoid any
        // self-access ordering ambiguity in the init body.
        let onboardingDone = UserDefaults.standard.bool(forKey: "stepin.hasCompletedOnboarding")
        self.hasCompletedOnboarding = onboardingDone
        self.hasProfile = hasProfile
        // iOS Keychain persists across app deletes and UserDefaults resets.
        // Only restore a saved session when onboarding is already complete.
        // If onboarding is pending, any stale Keychain credential must NOT
        // set isAuthenticated = true and skip AuthenticationView.
        let restoredUser = onboardingDone ? authenticationService.restoreSession() : nil
        self.authenticationService = authenticationService
        self.currentUser = restoredUser
        self.isAuthenticated = restoredUser != nil
        self.shouldValidateRestoredSession = true
    }

    /// Preview-only: bypasses UserDefaults and Keychain so Canvas always starts from a known state.
    init(
        hasProfile: Bool,
        hasCompletedOnboarding: Bool,
        isAuthenticated: Bool = true,
        currentUser: AuthenticatedUser? = AuthenticatedUser(id: "preview-user", email: "nayar@example.com", provider: .apple),
        authenticationService: AuthenticationServiceProtocol = StepINAuthenticationService()
    ) {
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.hasProfile = hasProfile
        self.authenticationService = authenticationService
        self.currentUser = isAuthenticated ? currentUser : nil
        self.isAuthenticated = isAuthenticated
        self.shouldValidateRestoredSession = false
    }

    func completeOnboarding() {
        hasCompletedOnboarding = true
        UserDefaults.standard.set(true, forKey: onboardingKey)
    }

    func authenticate(_ user: AuthenticatedUser) {
        currentUser = user
        isAuthenticated = true
    }

    func signOut() {
        authenticationService.signOut()
        currentUser = nil
        isAuthenticated = false
        selectedTab = .home
    }

    func validateRestoredSessionIfNeeded() async {
        guard shouldValidateRestoredSession, let currentUser else { return }
        do {
            try await authenticationService.validateAppleCredentialIfNeeded(for: currentUser)
        } catch {
            signOut()
        }
    }
}
