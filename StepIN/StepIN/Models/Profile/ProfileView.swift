//
//  ProfileView.swift
//  StepIN
//
//  Local profile overview with Edit Profile. CVs are attached per interview
//  in Interview Setup — the profile no longer stores or shows a CV.
//

import SwiftUI
import SwiftData

struct ProfileView: View {
    var embedsInNavigationStack = true

    @Query private var profiles: [UserProfile]

    @State private var showEditProfile = false

    private var profile: UserProfile? { profiles.first }

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
                header
                profileFields
            }
            .padding(.horizontal, StepINSpacing.screenH)
            .padding(.top, StepINSpacing.md)
            .padding(.bottom, StepINSpacing.giant)
        }
        .background(StepINScreenBackground())
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if profile != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { showEditProfile = true }
                        .fontWeight(.semibold)
                        .foregroundStyle(StepINColor.primary)
                }
            }
        }
        .sheet(isPresented: $showEditProfile) {
            if let profile {
                EditProfileView(profile: profile)
            }
        }
    }

    private var header: some View {
        VStack(spacing: StepINSpacing.sm) {
            ZStack {
                Circle()
                    .fill(StepINColor.primarySoft)
                    .frame(width: 102, height: 102)
                Text(initials)
                    .font(StepINFont.h1)
                    .foregroundColor(StepINColor.primary)
            }
            .overlay(
                Circle()
                    .strokeBorder(Color.white.opacity(0.9), lineWidth: 1)
            )
            .shadow(color: StepINColor.shadow.opacity(0.35), radius: 10, x: 0, y: 4)

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
        .modelContainer(PreviewData.container)
}
