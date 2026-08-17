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
        case preparing(InterviewConfiguration, InterviewSessionViewModel)
        case session(InterviewConfiguration, InterviewSessionViewModel?)
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
                        #if DEBUG
                        print("[InterviewStartup] T0 Start Interview tapped")
                        #endif
                        let viewModel = makeSessionViewModel(for: config)
                        withAnimation(StepINMotion.fade) { stage = .preparing(config, viewModel) }
                    },
                    onCancel: onDismiss
                )

            case .preparing(let config, let viewModel):
                AIPreparationView(configuration: config, startupViewModel: viewModel) {
                    sessionStartDate = .now
                    withAnimation(StepINMotion.fade) { stage = .session(config, viewModel) }
                }

            case .session(let config, let viewModel):
                InterviewSessionView(
                    configuration: config,
                    viewModel: viewModel,
                    onFinished: finishHandler(for: config)
                )

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

            case .analysisFailed:
                AnalysisFailedView(onDismiss: onDismiss)
            }
        }
    }

    // MARK: Persistence

    private func makeSessionViewModel(for config: InterviewConfiguration) -> InterviewSessionViewModel {
        InterviewSessionViewModel(
            configuration: config,
            onFinished: finishHandler(for: config)
        )
    }

    private func finishHandler(for config: InterviewConfiguration) -> (_ transcript: [TranscriptEntry], _ isPartial: Bool, _ completedCount: Int, _ metrics: VoiceDeliveryMetrics) -> Void {
        { transcript, isPartial, completedCount, metrics in
            withAnimation(StepINMotion.fade) { stage = .analyzing }
            Task {
                await analyzeAndSave(
                    config: config,
                    transcript: transcript,
                    isPartial: isPartial,
                    completedCount: completedCount,
                    metrics: metrics
                )
            }
        }
    }

    /// Saves the interview record first (transcript is never lost), then
    /// generates analysis + goals. Analysis failure keeps the record and
    /// shows a recoverable error.
    @MainActor
    private func analyzeAndSave(
        config: InterviewConfiguration,
        transcript: [TranscriptEntry],
        isPartial: Bool,
        completedCount: Int,
        metrics: VoiceDeliveryMetrics
    ) async {
        #if DEBUG
        let analysisT0 = Date.now
        print("[StepIN.AnalysisTiming] T0 analysis begins")
        #endif

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

        #if DEBUG
        print("[StepIN.AnalysisTiming] T1 initial transcript persistence completed: \(Date.now.timeIntervalSince(analysisT0))s")
        #endif

        // Evidence-sufficiency gate: CV content is interview context, not performance
        // evidence. If the candidate produced no meaningful answers (< 10 total words),
        // skip analysis entirely so the CV cannot generate a fabricated score.
        let candidateWordCount = transcript
            .filter { $0.speaker == .candidate }
            .reduce(0) { $0 + $1.text.split(separator: " ").count }
        guard candidateWordCount >= 10 else {
            interview.status = .completed
            try? context.save()
            #if DEBUG
            print("[StepIN.AnalysisTiming] T6 persistence completed: \(Date.now.timeIntervalSince(analysisT0))s")
            #endif
            withAnimation(StepINMotion.fade) { stage = .results(interview, []) }
            #if DEBUG
            print("[StepIN.AnalysisTiming] T7 Results shown: \(Date.now.timeIntervalSince(analysisT0))s")
            #endif
            return
        }

        // 2. Generate the analysis. Retry once only for transient failures.
        let service: InterviewAnalysisServiceProtocol = if let apiKey = OpenAIConfiguration.apiKey {
            OpenAIAnalysisService(apiKey: apiKey)
        } else {
            MockAnalysisService()
        }
        var result: AnalysisResult?
        var lastAnalysisError: Error?
        for attempt in 0..<2 {
            do {
                result = try await service.analyze(
                    configuration: config,
                    transcript: transcript,
                    isPartial: isPartial,
                    completedQuestionCount: completedCount,
                    deliveryMetrics: metrics
                )
                break
            } catch {
                lastAnalysisError = error
                #if DEBUG
                print("[StepIN.AnalysisTiming] analysis attempt \(attempt + 1) failed retryable=\(Self.isRetryableAnalysisError(error)): \(error)")
                #endif
                guard attempt == 0, Self.isRetryableAnalysisError(error) else { break }
            }
        }

        guard let result else {
            interview.status = .failed
            try? context.save()
            #if DEBUG
            print("[StepIN.AnalysisTiming] analysis failed: \(String(describing: lastAnalysisError))")
            print("[StepIN.AnalysisTiming] T6 persistence completed: \(Date.now.timeIntervalSince(analysisT0))s")
            #endif
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

        #if DEBUG
        print("[StepIN.AnalysisTiming] T6 persistence completed: \(Date.now.timeIntervalSince(analysisT0))s")
        #endif

        withAnimation(StepINMotion.fade) { stage = .results(interview, goals) }

        #if DEBUG
        print("[StepIN.AnalysisTiming] T7 Results shown: \(Date.now.timeIntervalSince(analysisT0))s")
        #endif
    }

    private static func isRetryableAnalysisError(_ error: Error) -> Bool {
        if let requestError = error as? AnalysisRequestError {
            return requestError.isRetryable
        }
        if let urlError = error as? URLError {
            return [
                .timedOut,
                .cannotFindHost,
                .cannotConnectToHost,
                .networkConnectionLost,
                .notConnectedToInternet,
                .dnsLookupFailed
            ].contains(urlError.code)
        }
        return false
    }

}

// MARK: - Analysis failure view

private struct AnalysisFailedView: View {
    let onDismiss: () -> Void
    @State private var oneShot: RobertAnimationState? = .confused

    var body: some View {
        VStack(spacing: StepINSpacing.xl) {
            Spacer()
            RobotView(
                state: .idle,
                robertState: oneShot,
                presentation: .emptyState,
                onOneShotComplete: { oneShot = nil }
            )
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
