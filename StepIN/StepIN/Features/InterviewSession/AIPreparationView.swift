//
//  AIPreparationView.swift
//  StepIN
//
//  Pre-interview moment: robot in Thinking state with a progressive
//  checklist. ~4-6 seconds, no skip, auto-advances into the interview.
//

import SwiftUI

struct AIPreparationView: View {
    let configuration: InterviewConfiguration
    let onReady: () -> Void

    @State private var visibleCount = 0

    /// Checklist items tailored to what the user actually provided.
    private var items: [String] {
        var list: [String] = []
        if configuration.resolvedCVText != nil { list.append("Reading your CV") }
        if configuration.jobDescription != nil { list.append("Understanding your Job Description") }
        if configuration.company != nil { list.append("Understanding the Company") }
        list.append("Understanding your background")
        list.append("Preparing personalized questions")
        list.append("Almost ready")
        return list
    }

    var body: some View {
        ZStack {
            StepINColor.background.ignoresSafeArea()

            VStack(spacing: StepINSpacing.xxl) {
                Spacer()
                RobotView(state: .thinking, size: 140)

                VStack(alignment: .leading, spacing: StepINSpacing.md) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        if index < visibleCount {
                            HStack(spacing: StepINSpacing.sm) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(StepINColor.success)
                                Text(item)
                                    .font(StepINFont.body1)
                                    .foregroundColor(StepINColor.textPrimary)
                            }
                            .transition(.opacity)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, StepINSpacing.xxl)
                .animation(StepINMotion.fade, value: visibleCount)

                Spacer()
                Spacer()
            }
        }
        .task {
            // Reveal items progressively across ~5 seconds, then enter.
            let step = 5.0 / Double(items.count)
            for _ in items {
                try? await Task.sleep(for: .seconds(step))
                visibleCount += 1
            }
            try? await Task.sleep(for: .seconds(0.6))
            onReady()
        }
        .accessibilityLabel("Preparing your interview")
    }
}

#Preview {
    AIPreparationView(
        configuration: InterviewConfiguration(
            jobTitle: "iOS Engineer",
            company: "Apple",
            companyWebsite: nil,
            jobDescription: "Build great apps.",
            interviewCV: nil,
            resolvedCVText: "CV text",
            questionCount: .five,
            candidateFirstName: "Nayar"
        ),
        onReady: {}
    )
}
