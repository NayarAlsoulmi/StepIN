//
//  EditProfileView.swift
//  StepIN
//
//  Edit name and email. Save / Cancel. Only First Name is required.
//  CVs are handled per interview in Interview Setup, not here.
//

import SwiftUI
import SwiftData

struct EditProfileView: View {
    let profile: UserProfile

    @Environment(\.dismiss) private var dismiss

    @State private var firstName: String
    @State private var lastName: String
    @State private var email: String

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
            .background(StepINColor.background)
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

        profile.updatedAt = .now
        dismiss()
    }
}

#Preview {
    EditProfileView(profile: PreviewData.sampleProfile())
        .modelContainer(PreviewData.container)
}
