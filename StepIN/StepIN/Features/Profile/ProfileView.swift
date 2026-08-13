//
//  ProfileView.swift
//  StepIN
//
//  Local profile overview with Edit Profile. CVs are attached per interview
//  in Interview Setup — the profile no longer stores or shows a CV.
//

import SwiftUI
import SwiftData
import UIKit

struct ProfileView: View {
    var embedsInNavigationStack = true

    @Environment(AppState.self) private var appState
    @Query private var profiles: [UserProfile]

    @State private var showEditProfile = false
    @State private var showSignOutConfirmation = false

    private var profile: UserProfile? { profiles.first }
    private var profileImage: UIImage? {
        ProfileImageService.image(atLocalPath: profile?.profileImageLocalPath)
    }

    @ViewBuilder
    var body: some View {
        if embedsInNavigationStack {
            NavigationStack {
                profileContent
            }
        } else {
            profileContent
        }
    }

    private var profileContent: some View {
        ScrollView {
            VStack(spacing: StepINSpacing.xl) {
                profileTopBar
                header
                profileFields
                signOutButton
            }
            .padding(.horizontal, StepINSpacing.screenH)
            .padding(.top, StepINSpacing.md)
            .padding(.bottom, StepINSpacing.giant)
        }
        .background(StepINScreenBackground())
        .toolbar(embedsInNavigationStack ? .hidden : .visible, for: .navigationBar)
        .sheet(isPresented: $showEditProfile) {
            if let profile {
                EditProfileView(profile: profile)
            }
        }
        .alert("Sign out?", isPresented: $showSignOutConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Sign Out", role: .destructive) {
                appState.signOut()
            }
        } message: {
            Text("Your interviews, goals, analyses, and profile stay on this device.")
        }
    }

    private var profileTopBar: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Profile")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundColor(StepINColor.textPrimary)

            Spacer()

            if profile != nil {
                Button("Edit") { showEditProfile = true }
                    .font(StepINFont.body2)
                    .foregroundStyle(StepINColor.primary)
            }
        }
    }

    private var header: some View {
        VStack(spacing: StepINSpacing.sm) {
            StepINProfileAvatar(
                image: profileImage,
                initials: initials,
                size: 102,
                initialsFont: StepINFont.h1
            )

            Text(displayFirstName)
                .font(StepINFont.h3)
                .foregroundColor(StepINColor.textPrimary)
        }
        .frame(maxWidth: .infinity)
    }

    private var profileFields: some View {
        StepINCard(padding: StepINSpacing.md) {
            VStack(spacing: StepINSpacing.sm) {
                profileRow(label: "First Name", value: profile?.firstName)
                Divider().background(StepINColor.divider)
                profileRow(label: "Last Name", value: profile?.lastName)
                Divider().background(StepINColor.divider)
                profileRow(label: "Email", value: profile?.email)
            }
        }
    }

    private var signOutButton: some View {
        StepINDestructiveButton(title: "Sign Out") {
            showSignOutConfirmation = true
        }
    }

    private func profileRow(label: String, value: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: StepINSpacing.md) {
            Text(label)
                .font(StepINFont.body3)
                .foregroundColor(StepINColor.textSecondary)
            Spacer(minLength: StepINSpacing.md)
            Text(value?.nilIfBlank ?? "—")
                .font(StepINFont.body2)
                .foregroundColor(StepINColor.textPrimary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, StepINSpacing.xxs)
    }

    private var displayFirstName: String {
        profile?.firstName.nilIfBlank ?? "Your Profile"
    }

    private var initials: String {
        guard let profile else { return "?" }
        let first = profile.firstName.first.map(String.init) ?? ""
        let last = profile.lastName?.first.map(String.init) ?? ""
        return (first + last).uppercased()
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

#Preview {
    ProfileView()
        .environment(AppState(hasProfile: true, hasCompletedOnboarding: true, isAuthenticated: true))
        .modelContainer(PreviewData.container)
}
