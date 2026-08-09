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
    @Query private var profiles: [UserProfile]

    @State private var showEditProfile = false

    private var profile: UserProfile? { profiles.first }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: StepINSpacing.section) {
                    header
                    profileFields
                }
                .padding(.horizontal, StepINSpacing.screenH)
                .padding(.top, StepINSpacing.sm)
                .padding(.bottom, StepINSpacing.giant)
            }
            .background(StepINColor.background)
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.large)
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
        }
        .frame(maxWidth: .infinity)
    }

    private var profileFields: some View {
        StepINCard {
            VStack(spacing: StepINSpacing.md) {
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
    }

    private var fullName: String {
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
