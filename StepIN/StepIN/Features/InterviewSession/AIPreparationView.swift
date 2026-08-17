//
//  AIPreparationView.swift
//  StepIN
//
//  Pre-interview moment: robot in Thinking state with a progressive checklist.
//  Real readiness owns navigation; checklist animation must never block startup.
//

import SwiftUI

struct AIPreparationView: View {
    let configuration: InterviewConfiguration
    let startupViewModel: InterviewSessionViewModel?
    let onReady: () -> Void

    @State private var visibleCount = 0
    @State private var didRequestStart = false
    @State private var didAdvance = false
    @State private var animationCompleted = false
    @State private var finalReadinessFrameRendered = false
    @State private var didScheduleFinalReadinessFrame = false
    @State private var realtimeReady = false
    @State private var realtimeFailed = false
    private let finalReadinessFadeDuration: TimeInterval = 0.3

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

    private var preparationItems: [String] {
        Array(items.dropLast())
    }

    var body: some View {
        ZStack {
            StepINScreenBackground()

            VStack(spacing: StepINSpacing.xxl) {
                Spacer()
                RobotView(state: .thinking, presentation: .loading)

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
            #if DEBUG
            print("[InterviewStartup] T1 preparation screen shown")
            #endif
            if !didRequestStart {
                didRequestStart = true
                startupViewModel?.prepare()
            }

            let step = 4.5 / 5.0
            for _ in preparationItems where !Task.isCancelled {
                try? await Task.sleep(for: .seconds(step))
                visibleCount += 1
            }
            animationCompleted = true
            completeFinalReadinessIfPossible()
        }
        .onChange(of: startupViewModel?.phase) { _, phase in
            guard let phase else { return }
            if phase == .error {
                realtimeFailed = true
                advanceIfReady()
            } else if phase == .ready {
                realtimeReady = true
                completeFinalReadinessIfPossible()
                advanceIfReady()
            }
        }
        .accessibilityLabel("Preparing your interview")
    }

    private func completeFinalReadinessIfPossible() {
        guard animationCompleted, realtimeReady else {
            advanceIfReady()
            return
        }
        guard visibleCount < items.count else {
            finalReadinessFrameRendered = true
            advanceIfReady()
            return
        }
        guard !didScheduleFinalReadinessFrame else { return }
        didScheduleFinalReadinessFrame = true
        visibleCount = items.count

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(finalReadinessFadeDuration))
            #if DEBUG
            print("[InterviewStartup] T6 preparation animation completed")
            #endif
            finalReadinessFrameRendered = true
            advanceIfReady()
        }
    }

    private func advanceIfReady() {
        guard !didAdvance else { return }
        if realtimeFailed {
            didAdvance = true
            onReady()
            return
        }
        guard animationCompleted, realtimeReady, finalReadinessFrameRendered else { return }
        guard !didAdvance else { return }
        didAdvance = true
        onReady()
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
        startupViewModel: nil,
        onReady: {}
    )
}
