//
//  CreateProfileView.swift
//  StepIN
//
//  Local profile creation. No login, no password — everything stays on
//  device. Only First Name is required.
//

import SwiftUI
import SwiftData

struct CreateProfileView: View {
    /// Called after the profile has been created.
    let onFinished: () -> Void

    @Environment(\.modelContext) private var context

    @State private var firstName = ""
    @State private var lastName = ""
    @State private var email = ""
    @State private var importedCV: ImportedCV?

    private var canContinue: Bool {
        !firstName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: StepINSpacing.xl) {
                    VStack(spacing: StepINSpacing.sm) {
                        RobotView(state: .idle, size: 90)
                        Text("Let's get to know you")
                            .font(StepINFont.h2)
                            .foregroundColor(StepINColor.textPrimary)
                        Text("Your details stay on this device and help personalize your interviews.")
                            .font(StepINFont.bodyRegular)
                            .foregroundColor(StepINColor.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)

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
                            fileName: importedCV?.fileName,
                            onImport: { importedCV = $0 },
                            onRemove: { removeCV() }
                        )
                        Text("Your CV is used to personalize the interview. The file stays on your device; relevant text may be sent securely during an interview.")
                            .font(StepINFont.caption)
                            .foregroundColor(StepINColor.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    StepINPrimaryButton(title: "Continue", isEnabled: canContinue) {
                        createProfile()
                    }
                }
                .padding(StepINSpacing.screenH)
            }
            .background(StepINColor.background)
            .navigationTitle("Create Profile")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func removeCV() {
        if let cv = importedCV {
            CVDocumentService().deleteCV(atLocalPath: cv.localPath)
        }
        importedCV = nil
    }

    private func createProfile() {
        let trimmedFirst = firstName.trimmingCharacters(in: .whitespaces)
        guard !trimmedFirst.isEmpty else { return }

        let trimmedLast = lastName.trimmingCharacters(in: .whitespaces)
        let trimmedEmail = email.trimmingCharacters(in: .whitespaces)

        let profile = UserProfile(
            firstName: trimmedFirst,
            lastName: trimmedLast.isEmpty ? nil : trimmedLast,
            email: trimmedEmail.isEmpty ? nil : trimmedEmail,
            profileCVFileName: importedCV?.fileName,
            profileCVLocalPath: importedCV?.localPath,
            profileCVExtractedText: importedCV?.extractedText
        )
        context.insert(profile)
        onFinished()
    }
}

// MARK: - Text field

/// Labeled single-line field in the StepIN form style. The entire row is
/// tappable and drives focus explicitly for reliability.
struct StepINTextField: View {
    let label: String
    @Binding var text: String
    var isRequired: Bool = false

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: StepINSpacing.xs) {
            HStack(spacing: 4) {
                Text(label)
                    .font(StepINFont.body3)
                    .foregroundColor(StepINColor.textSecondary)
                if !isRequired {
                    Text("Optional")
                        .font(StepINFont.caption)
                        .foregroundColor(StepINColor.textTertiary)
                }
            }
            TextField(label, text: $text)
                .focused($isFocused)
                .font(StepINFont.bodyRegular)
                .padding(StepINSpacing.md)
                .background(StepINColor.surface)
                .clipShape(RoundedRectangle(cornerRadius: StepINRadius.small, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: StepINRadius.small, style: .continuous)
                        .stroke(isFocused ? StepINColor.primary : StepINColor.border, lineWidth: 1)
                )
        }
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
    }
}

#Preview {
    CreateProfileView(onFinished: {})
        .modelContainer(PreviewData.emptyContainer)
}
