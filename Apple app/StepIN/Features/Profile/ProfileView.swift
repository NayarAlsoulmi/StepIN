//
//  ProfileView.swift
//  StepIN
//
//  Local profile overview with Edit Profile and CV replace / delete.
//

import SwiftUI
import SwiftData

struct ProfileView: View {
    @Query private var profiles: [UserProfile]

    @State private var showEditProfile = false
    @State private var confirmDeleteCV = false

    private var profile: UserProfile? { profiles.first }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: StepINSpacing.section) {
                    header
                    detailsCard
                    cvSection
                }
                .padding(StepINSpacing.screenH)
                .padding(.bottom, StepINSpacing.xxl)
            }
            .background(StepINColor.background)
            .navigationTitle("Profile")
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
            .confirmationDialog(
                "Delete your CV?",
                isPresented: $confirmDeleteCV,
                titleVisibility: .visible
            ) {
                Button("Delete CV", role: .destructive) { deleteCV() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This won't affect CVs used by past interviews.")
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

    @ViewBuilder
    private var cvSection: some View {
        VStack(alignment: .leading, spacing: StepINSpacing.sm) {
            StepINSectionHeader(title: "CV")
            if let profile {
                CVUploadCard(
                    fileName: profile.profileCVFileName,
                    onImport: { imported in replaceCV(with: imported) },
                    onRemove: profile.hasCV ? { confirmDeleteCV = true } : nil
                )
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

    // MARK: CV actions

    private func replaceCV(with imported: ImportedCV) {
        guard let profile else { return }
        if let oldPath = profile.profileCVLocalPath {
            CVDocumentService().deleteCV(atLocalPath: oldPath)
        }
        profile.profileCVFileName = imported.fileName
        profile.profileCVLocalPath = imported.localPath
        profile.profileCVExtractedText = imported.extractedText
        profile.updatedAt = .now
    }

    /// Deleting the Profile CV never deletes CV copies owned by past interviews.
    private func deleteCV() {
        guard let profile else { return }
        if let oldPath = profile.profileCVLocalPath {
            CVDocumentService().deleteCV(atLocalPath: oldPath)
        }
        profile.profileCVFileName = nil
        profile.profileCVLocalPath = nil
        profile.profileCVExtractedText = nil
        profile.updatedAt = .now
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
