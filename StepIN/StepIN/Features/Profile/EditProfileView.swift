//
//  EditProfileView.swift
//  StepIN
//
//  Edit name, email, and CV. Save / Cancel. Only First Name is required.
//

import SwiftUI
import SwiftData

struct EditProfileView: View {
    let profile: UserProfile

    @Environment(\.dismiss) private var dismiss

    @State private var firstName: String
    @State private var lastName: String
    @State private var email: String
    /// Newly imported CV pending save, if any.
    @State private var pendingCV: ImportedCV?
    /// Whether the user removed the existing CV (applied on Save).
    @State private var removedExistingCV = false

    init(profile: UserProfile) {
        self.profile = profile
        _firstName = State(initialValue: profile.firstName)
        _lastName = State(initialValue: profile.lastName ?? "")
        _email = State(initialValue: profile.email ?? "")
    }

    private var canSave: Bool {
        !firstName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var displayedCVName: String? {
        if let pendingCV { return pendingCV.fileName }
        if removedExistingCV { return nil }
        return profile.profileCVFileName
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: StepINSpacing.xl) {
                    VStack(alignment: .leading, spacing: StepINSpacing.md) {
                        StepINTextField(label: "First Name", text: $firstName, isRequired: true)
                            .textContentType(.givenName)
                        StepINTextField(label: "Last Name", text: $lastName)
                            .textContentType(.familyName)
                        StepINTextField(label: "Email", text: $email)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                    }

                    VStack(alignment: .leading, spacing: StepINSpacing.xs) {
                        Text("CV")
                            .font(StepINFont.body3)
                            .foregroundColor(StepINColor.textSecondary)
                        CVUploadCard(
                            fileName: displayedCVName,
                            onImport: { imported in
                                // Discard a previously pending (unsaved) file.
                                if let pendingCV {
                                    CVDocumentService().deleteCV(atLocalPath: pendingCV.localPath)
                                }
                                pendingCV = imported
                                removedExistingCV = false
                            },
                            onRemove: {
                                if let pendingCV {
                                    CVDocumentService().deleteCV(atLocalPath: pendingCV.localPath)
                                    self.pendingCV = nil
                                } else {
                                    removedExistingCV = true
                                }
                            }
                        )
                    }
                }
                .padding(StepINSpacing.screenH)
            }
            .background(StepINColor.background)
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func cancel() {
        // Remove any file imported during this editing session.
        if let pendingCV {
            CVDocumentService().deleteCV(atLocalPath: pendingCV.localPath)
        }
        dismiss()
    }

    private func save() {
        let trimmedFirst = firstName.trimmingCharacters(in: .whitespaces)
        guard !trimmedFirst.isEmpty else { return }

        profile.firstName = trimmedFirst
        let trimmedLast = lastName.trimmingCharacters(in: .whitespaces)
        profile.lastName = trimmedLast.isEmpty ? nil : trimmedLast
        let trimmedEmail = email.trimmingCharacters(in: .whitespaces)
        profile.email = trimmedEmail.isEmpty ? nil : trimmedEmail

        // CV changes. Note: deleting the Profile CV never touches CV copies
        // referenced by past interviews (they own their own files).
        if let pendingCV {
            if let oldPath = profile.profileCVLocalPath {
                CVDocumentService().deleteCV(atLocalPath: oldPath)
            }
            profile.profileCVFileName = pendingCV.fileName
            profile.profileCVLocalPath = pendingCV.localPath
            profile.profileCVExtractedText = pendingCV.extractedText
        } else if removedExistingCV {
            if let oldPath = profile.profileCVLocalPath {
                CVDocumentService().deleteCV(atLocalPath: oldPath)
            }
            profile.profileCVFileName = nil
            profile.profileCVLocalPath = nil
            profile.profileCVExtractedText = nil
        }

        profile.updatedAt = .now
        dismiss()
    }
}

#Preview {
    EditProfileView(profile: PreviewData.sampleProfile())
        .modelContainer(PreviewData.container)
}
