//
//  InterviewFlowView.swift
//  StepIN
//
//  Full-screen interview flow coordinator:
//  Setup → AI Preparation → Session → Analyzing → Results.
//  Saves the interview, analysis, and goals BEFORE showing results.
//  Practice Again creates a brand-new record — history is never overwritten.
//

import SwiftUI
import SwiftData

struct InterviewFlowView: View {
    let onDismiss: () -> Void

    @Environment(\.modelContext) private var context

    private enum Stage {
        case setup(prefill: InterviewConfiguration?)
        case preparing(InterviewConfiguration)
        case session(InterviewConfiguration)
        case analyzing
        case results(InterviewRecord, [AssignedGoal])
        case analysisFailed(InterviewRecord)
    }

    @State private var stage: Stage = .setup(prefill: nil)
    @State private var sessionStartDate = Date.now

    var body: some View {
        ZStack {
            switch stage {
            case .setup(let prefill):
                InterviewSetupView(
                    prefill: prefill,
                    onGenerate: { config in
                        withAnimation(StepINMotion.fade) { stage = .preparing(config) }
                    },
                    onCancel: onDismiss
                )

            case .preparing(let config):
                AIPreparationView(configuration: config) {
                    sessionStartDate = .now
                    withAnimation(StepINMotion.fade) { stage = .session(config) }
                }

            case .session(let config):
                InterviewSessionView(configuration: config) { transcript, isPartial, completedCount in
                    withAnimation(StepINMotion.fade) { stage = .analyzing }
                    Task {
                        await analyzeAndSave(
                            config: config,
                            transcript: transcript,
                            isPartial: isPartial,
                            completedCount: completedCount
                        )
                    }
                }

            case .analyzing:
                AnalyzingView()

            case .results(let interview, let goals):
                NavigationStack {
                    ResultsView(
                        interview: interview,
                        goals: goals,
                        onPracticeAgain: {
                            // Reuse previous context; user edits before starting.
                            let prefill = InterviewConfiguration(
                                jobTitle: interview.jobTitle,
                                company: interview.company,
                                companyWebsite: interview.companyWebsite,
                                jobDescription: interview.jobDescription,
                                interviewCV: nil,
                                resolvedCVText: nil,
                                questionCount: QuestionCount(rawValue: interview.selectedQuestionCount) ?? .five,
                                candidateFirstName: ""
                            )
                            withAnimation(StepINMotion.fade) { stage = .setup(prefill: prefill) }
                        },
                        onReturnHome: onDismiss
                    )
                    .navigationTitle("Your Results")
                    .navigationBarTitleDisplayMode(.inline)
                }

            case .analysisFailed(let interview):
                analysisFailedView(interview: interview)
            }
        }
    }

    // MARK: Persistence

    /// Saves the interview record first (transcript is never lost), then
    /// generates analysis + goals. Analysis failure keeps the record and
    /// shows a recoverable error.
    @MainActor
    private func analyzeAndSave(
        config: InterviewConfiguration,
        transcript: [TranscriptEntry],
        isPartial: Bool,
        completedCount: Int
    ) async {
        let analyzingShownAt = Date.now

        // 1. Save the interview + transcript immediately.
        let interview = InterviewRecord(
            title: config.displayTitle,
            jobTitle: config.jobTitle,
            company: config.company,
            companyWebsite: config.companyWebsite,
            jobDescription: config.jobDescription,
            interviewCVFileName: config.interviewCV?.fileName,
            interviewCVLocalPath: config.interviewCV?.localPath,
            resolvedCVText: config.resolvedCVText,
            selectedQuestionCount: config.questionCount.rawValue,
            completedQuestionCount: completedCount,
            startedAt: sessionStartDate,
            endedAt: .now,
            duration: Date.now.timeIntervalSince(sessionStartDate),
            isPartial: isPartial,
            status: .analyzing
        )
        context.insert(interview)
        for (index, entry) in transcript.enumerated() {
            let message = InterviewMessage(speaker: entry.speaker, text: entry.text, sequenceNumber: index)
            message.interview = interview
            context.insert(message)
        }
        try? context.save()

        // 2. Generate the analysis (retry once per spec).
        let service = MockAnalysisService()
        var result: AnalysisResult?
        for _ in 0..<2 {
            result = try? await service.analyze(
                configuration: config,
                transcript: transcript,
                isPartial: isPartial,
                completedQuestionCount: completedCount
            )
            if result != nil { break }
        }

        guard let result else {
            interview.status = .failed
            try? context.save()
            withAnimation(StepINMotion.fade) { stage = .analysisFailed(interview) }
            return
        }

        // 3. Attach analysis and create goals.
        let analysis = InterviewAnalysis(
            overallScore: result.overallScore,
            answerQualityScore: result.answerQualityScore,
            clarityScore: result.clarityScore,
            confidenceScore: result.confidenceScore,
            communicationScore: result.communicationScore,
            interviewSkillsScore: result.interviewSkillsScore,
            strengths: result.strengths,
            areasToImprove: result.areasToImprove,
            summary: result.summary
        )
        interview.analysis = analysis
        interview.overallScore = result.overallScore
        interview.status = .completed

        var goals: [AssignedGoal] = []
        for title in result.assignedGoals {
            let goal = AssignedGoal(
                interviewID: interview.id,
                title: title,
                sourceInterviewTitle: interview.title,
                sourceJobTitle: interview.jobTitle,
                sourceCompany: interview.company
            )
            context.insert(goal)
            goals.append(goal)
        }
        try? context.save()

        // Keep the analyzing moment ~4.5s minimum so the checklist reads naturally.
        let elapsed = Date.now.timeIntervalSince(analyzingShownAt)
        if elapsed < 4.5 {
            try? await Task.sleep(for: .seconds(4.5 - elapsed))
        }

        withAnimation(StepINMotion.fade) { stage = .results(interview, goals) }
    }

    // MARK: Analysis failure (recoverable)

    private func analysisFailedView(interview: InterviewRecord) -> some View {
        VStack(spacing: StepINSpacing.xl) {
            Spacer()
            RobotView(state: .idle, size: 110)
            Text("We couldn't finish your analysis")
                .font(StepINFont.h3)
                .foregroundColor(StepINColor.textPrimary)
            Text("Your interview and transcript are saved. You can find them in My Interviews.")
                .font(StepINFont.bodyRegular)
                .foregroundColor(StepINColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, StepINSpacing.xxl)
            Spacer()
            StepINPrimaryButton(title: "Return Home", action: onDismiss)
                .padding(.horizontal, StepINSpacing.screenH)
                .padding(.bottom, StepINSpacing.xl)
        }
        .background(StepINColor.background.ignoresSafeArea())
    }
}
