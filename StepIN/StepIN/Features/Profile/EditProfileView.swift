//
//  EditProfileView.swift
//  StepIN
//
//  Edit name and email. Save / Cancel. Only First Name is required.
//  CVs are handled per interview in Interview Setup, not here.
//

import SwiftUI
import SwiftData
import PhotosUI
import UIKit

struct EditProfileView: View {
    let profile: UserProfile

    @Environment(\.dismiss) private var dismiss

    @State private var firstName: String
    @State private var lastName: String
    @State private var email: String
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var selectedImageData: Data?
    @State private var shouldRemoveImage = false
    @State private var imageErrorMessage: String?
    @State private var isLoadingImage = false

    private let imageService = ProfileImageService()

    init(profile: UserProfile) {
        self.profile = profile
        _firstName = State(initialValue: profile.firstName)
        _lastName = State(initialValue: profile.lastName ?? "")
        _email = State(initialValue: profile.email ?? "")
    }

    private var canSave: Bool {
        !firstName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: StepINSpacing.md) {
                    photoSection

                    StepINTextField(label: "First Name", text: $firstName, isRequired: true)
                        .textContentType(.givenName)
                    StepINTextField(label: "Last Name", text: $lastName)
                        .textContentType(.familyName)
                    StepINTextField(label: "Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                }
                .padding(StepINSpacing.screenH)
            }
            .background(StepINScreenBackground())
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                        .fontWeight(.semibold)
                }
            }
            .onChange(of: selectedPhoto) { _, newItem in
                Task { await loadSelectedPhoto(newItem) }
            }
        }
    }

    private var photoSection: some View {
        VStack(spacing: StepINSpacing.xs) {
            StepINProfileAvatar(
                image: displayedImage,
                initials: initials,
                size: 96,
                initialsFont: StepINFont.h2
            )

            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                Text(displayedImage == nil ? "Add Photo" : "Change Photo")
                    .font(StepINFont.body2)
                    .foregroundColor(StepINColor.primary)
            }
            .buttonStyle(.plain)
            .disabled(isLoadingImage)

            if displayedImage != nil {
                Button("Remove Photo") {
                    selectedPhoto = nil
                    selectedImageData = nil
                    shouldRemoveImage = true
                    imageErrorMessage = nil
                }
                .font(StepINFont.body3)
                .foregroundColor(StepINColor.error)
            }

            if isLoadingImage {
                ProgressView()
                    .tint(StepINColor.primary)
            }

            if let imageErrorMessage {
                Text(imageErrorMessage)
                    .font(StepINFont.caption)
                    .foregroundColor(StepINColor.error)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, StepINSpacing.sm)
    }

    private var displayedImage: UIImage? {
        if let selectedImageData {
            return UIImage(data: selectedImageData)
        }
        if shouldRemoveImage {
            return nil
        }
        return ProfileImageService.image(atLocalPath: profile.profileImageLocalPath)
    }

    private var initials: String {
        let first = firstName.first.map(String.init) ?? "?"
        let last = lastName.first.map(String.init) ?? ""
        return "\(first)\(last)".uppercased()
    }

    @MainActor
    private func loadSelectedPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }

        isLoadingImage = true
        imageErrorMessage = nil
        defer { isLoadingImage = false }

        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                imageErrorMessage = ProfileImageError.invalidImage.localizedDescription
                return
            }
            guard UIImage(data: data) != nil else {
                imageErrorMessage = ProfileImageError.invalidImage.localizedDescription
                return
            }

            selectedImageData = data
            shouldRemoveImage = false
        } catch {
            imageErrorMessage = error.localizedDescription
        }
    }

    private func save() {
        let trimmedFirst = firstName.trimmingCharacters(in: .whitespaces)
        guard !trimmedFirst.isEmpty else { return }

        profile.firstName = trimmedFirst
        let trimmedLast = lastName.trimmingCharacters(in: .whitespaces)
        profile.lastName = trimmedLast.isEmpty ? nil : trimmedLast
        let trimmedEmail = email.trimmingCharacters(in: .whitespaces)
        profile.email = trimmedEmail.isEmpty ? nil : trimmedEmail

        if shouldRemoveImage {
            imageService.deleteProfileImage(atLocalPath: profile.profileImageLocalPath)
            profile.profileImageLocalPath = nil
        } else if let selectedImageData {
            do {
                profile.profileImageLocalPath = try imageService.saveProfileImage(selectedImageData, for: profile.id)
            } catch {
                imageErrorMessage = error.localizedDescription
                return
            }
        }

        profile.updatedAt = .now
        dismiss()
    }
}

#Preview {
    EditProfileView(profile: PreviewData.sampleProfile())
        .modelContainer(PreviewData.container)
}
