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
            NavigationStack { profileContent }
        } else {
            profileContent
        }
    }

    private var profileContent: some View {
        ScrollView {
            VStack(spacing: StepINSpacing.section) {
                header
                detailsCard
            }
            .padding(StepINSpacing.screenH)
            .padding(.bottom, StepINSpacing.xxl)
        }
        .background(StepINScreenBackground())
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if profile != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { showEditProfile = true }
                        .fontWeight(.semibold)
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
                    .frame(width: 96, height: 96)
                Text(initials)
                    .font(StepINFont.h1)
                    .foregroundColor(StepINColor.primary)
            }
            Text(fullName)
                .font(StepINFont.h3)
                .foregroundColor(StepINColor.textPrimary)
            if let email = profile?.email {
                Text(email)
                    .font(StepINFont.body3)
                    .foregroundColor(StepINColor.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, StepINSpacing.md)
    }

    private var detailsCard: some View {
        StepINCard {
            VStack(spacing: StepINSpacing.md) {
                detailRow("First Name", profile?.firstName ?? "—")
                Divider().background(StepINColor.divider)
                detailRow("Last Name", profile?.lastName ?? "—")
                Divider().background(StepINColor.divider)
                detailRow("Email", profile?.email ?? "—")
            }
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(StepINFont.body3)
                .foregroundColor(StepINColor.textSecondary)
            Spacer()
            Text(value)
                .font(StepINFont.body2)
                .foregroundColor(StepINColor.textPrimary)
        }
    }

    private var fullName: String {
        guard let profile else { return "Your Profile" }
        return [profile.firstName, profile.lastName].compactMap { $0 }.joined(separator: " ")
    }

    private var initials: String {
        guard let profile else { return "?" }
        let first = profile.firstName.first.map(String.init) ?? ""
        let last = profile.lastName?.first.map(String.init) ?? ""
        return (first + last).uppercased()
    }
}

#Preview {
    ProfileView()
        .modelContainer(PreviewData.container)
}
