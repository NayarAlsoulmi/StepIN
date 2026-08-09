//
//  InterviewSetupView.swift
//  StepIN
//
//  Interview Preparation. Only Job Title is required — never block the
//  interview on anything else. CV rule: Interview CV if provided, otherwise
//  the interview continues without a CV (no Profile fallback).
//

import SwiftUI
import SwiftData

struct InterviewSetupView: View {
    /// Prefill values (used by Practice Again). All editable before starting.
    var prefill: InterviewConfiguration? = nil
    /// Called with the assembled configuration when Generate Interview is pressed.
    let onGenerate: (InterviewConfiguration) -> Void
    let onCancel: () -> Void

    @Query private var profiles: [UserProfile]

    @State private var jobTitle: String
    @State private var company: String
    @State private var companyWebsite: String
    @State private var jobDescription: String
    @State private var interviewCV: ImportedCV?
    @State private var questionCount: QuestionCount
    @FocusState private var jobDescriptionFocused: Bool

    init(
        prefill: InterviewConfiguration? = nil,
        onGenerate: @escaping (InterviewConfiguration) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.prefill = prefill
        self.onGenerate = onGenerate
        self.onCancel = onCancel
        // Dev/demo convenience: `-StepINPrefillJobTitle "..."` launch argument
        // prefills the field (registered into UserDefaults by the system).
        // No effect unless explicitly launched with the argument.
        let devPrefill = UserDefaults.standard.string(forKey: "StepINPrefillJobTitle")
        _jobTitle = State(initialValue: prefill?.jobTitle ?? devPrefill ?? "")
        _company = State(initialValue: prefill?.company ?? "")
        _companyWebsite = State(initialValue: prefill?.companyWebsite ?? "")
        _jobDescription = State(initialValue: prefill?.jobDescription ?? "")
        _questionCount = State(initialValue: prefill?.questionCount ?? .five)
    }

    private var profile: UserProfile? { profiles.first }

    private var canGenerate: Bool {
        !jobTitle.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: StepINSpacing.xl) {
                    Text("Tell us about the job you're preparing for. Only the job title is required.")
                        .font(StepINFont.bodyRegular)
                        .foregroundColor(StepINColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: StepINSpacing.md) {
                        StepINTextField(label: "Job Title", text: $jobTitle, isRequired: true)
                        StepINTextField(label: "Company", text: $company)
                        StepINTextField(label: "Company Website", text: $companyWebsite)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        // Multiline job description.
                        VStack(alignment: .leading, spacing: StepINSpacing.xs) {
                            HStack(spacing: 4) {
                                Text("Job Description")
                                    .font(StepINFont.body3)
                                    .foregroundColor(StepINColor.textSecondary)
                                Text("Optional")
                                    .font(StepINFont.caption)
                                    .foregroundColor(StepINColor.textTertiary)
                            }
                            TextEditor(text: $jobDescription)
                                .focused($jobDescriptionFocused)
                                .font(StepINFont.bodyRegular)
                                .frame(minHeight: 110)
                                .padding(StepINSpacing.xs)
                                .scrollContentBackground(.hidden)
                                .background(StepINColor.surface)
                                .clipShape(RoundedRectangle(cornerRadius: StepINRadius.small, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: StepINRadius.small, style: .continuous)
                                        .stroke(jobDescriptionFocused ? StepINColor.primary : StepINColor.border, lineWidth: 1)
                                )
                                .contentShape(Rectangle())
                                .onTapGesture { jobDescriptionFocused = true }
                                .accessibilityLabel("Job Description, optional")
                        }
                    }

                    // CV for this interview only — optional, no Profile fallback.
                    VStack(alignment: .leading, spacing: StepINSpacing.xs) {
                        Text("CV for this interview")
                            .font(StepINFont.body3)
                            .foregroundColor(StepINColor.textSecondary)
                        CVUploadCard(
                            fileName: interviewCV?.fileName,
                            onImport: { imported in
                                if let interviewCV {
                                    CVDocumentService().deleteCV(atLocalPath: interviewCV.localPath)
                                }
                                interviewCV = imported
                            },
                            onRemove: {
                                if let interviewCV {
                                    CVDocumentService().deleteCV(atLocalPath: interviewCV.localPath)
                                }
                                interviewCV = nil
                            }
                        )
                    }

                    // Question count.
                    VStack(alignment: .leading, spacing: StepINSpacing.xs) {
                        Text("Number of questions")
                            .font(StepINFont.body3)
                            .foregroundColor(StepINColor.textSecondary)
                        Picker("Number of questions", selection: $questionCount) {
                            ForEach(QuestionCount.allCases) { count in
                                Text(count.label).tag(count)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    StepINPrimaryButton(title: "Generate Interview", isEnabled: canGenerate) {
                        generate()
                    }
                }
                .padding(StepINSpacing.screenH)
                .padding(.bottom, StepINSpacing.xxl)
            }
            .background(StepINScreenBackground())
            .navigationTitle("New Interview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancel() }
                }
            }
        }
    }

    private func cancel() {
        // Discard an interview CV imported but never used.
        if let interviewCV {
            CVDocumentService().deleteCV(atLocalPath: interviewCV.localPath)
        }
        onCancel()
    }

    private func generate() {
        let trimmedTitle = jobTitle.trimmingCharacters(in: .whitespaces)
        guard !trimmedTitle.isEmpty else { return }

        func nonEmpty(_ value: String) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }

        // CV rule: Interview CV if provided, otherwise none. Never block.
        let resolvedCVText = interviewCV?.extractedText

        let config = InterviewConfiguration(
            jobTitle: trimmedTitle,
            company: nonEmpty(company),
            companyWebsite: nonEmpty(companyWebsite),
            jobDescription: nonEmpty(jobDescription),
            interviewCV: interviewCV,
            resolvedCVText: resolvedCVText,
            questionCount: questionCount,
            candidateFirstName: profile?.firstName ?? "there"
        )
        onGenerate(config)
    }
}

#Preview {
    InterviewSetupView(onGenerate: { _ in }, onCancel: {})
        .modelContainer(PreviewData.container)
}
