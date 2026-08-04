//
//  HomeView.swift
//  StepIN
//
//  Central dashboard: greeting, hero card, recent interviews, recent goals.
//

import SwiftUI
import SwiftData

struct HomeView: View {
    @Environment(AppState.self) private var appState
    @Query private var profiles: [UserProfile]
    @Query(sort: \InterviewRecord.startedAt, order: .reverse)
    private var interviews: [InterviewRecord]
    @Query(sort: \AssignedGoal.createdAt, order: .reverse)
    private var allGoals: [AssignedGoal]

    @State private var showInterviewFlow = false
    @State private var heroRobotState: RobotState = .idle
    // Drives one-shot override (wakeUp on entrance, wave on tap).
    @State private var heroOneShot: RobertAnimationState? = nil
    @State private var hasAppeared = false
    @State private var startFeedbackTrigger = false

    private var firstName: String { profiles.first?.firstName ?? "there" }

    private var completedInterviews: [InterviewRecord] {
        interviews.filter { $0.status == .completed }
    }
    private var recentInterviews: [InterviewRecord] {
        Array(completedInterviews.prefix(2))
    }

    private var activeGoals: [AssignedGoal] {
        allGoals.filter { $0.status == .toDo }
    }
    private var recentGoals: [AssignedGoal] {
        Array(activeGoals.prefix(3))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: StepINSpacing.section) {
                    heroCard
                    recentInterviewsSection
                    recentGoalsSection
                }
                .padding(.horizontal, StepINSpacing.screenH)
                .padding(.bottom, StepINSpacing.xxl)
            }
            .background(StepINColor.background)
            .navigationTitle("Welcome back, \(firstName)")
            .navigationDestination(for: UUID.self) { id in
                if let interview = interviews.first(where: { $0.id == id }) {
                    InterviewDetailsView(interview: interview)
                }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: startFeedbackTrigger)
            .fullScreenCover(isPresented: $showInterviewFlow) {
                InterviewFlowView {
                    showInterviewFlow = false
                    heroRobotState = .idle
                }
            }
        }
        .onAppear {
            guard !hasAppeared else { return }
            hasAppeared = true
            heroOneShot = .wakeUp
        }
    }

    // MARK: Hero

    private var heroCard: some View {
        VStack(spacing: StepINSpacing.md) {
            RobotView(
                state: heroRobotState,
                robertState: heroOneShot,
                presentation: .homeHero,
                onOneShotComplete: { heroOneShot = nil }
            )

            VStack(spacing: StepINSpacing.xs) {
                Text("Ready for your next interview?")
                    .font(StepINFont.h2)
                    .foregroundColor(StepINColor.onPrimary)
                    .multilineTextAlignment(.center)
                Text("Practice with an AI interviewer tailored to your role.")
                    .font(StepINFont.bodyRegular)
                    .foregroundColor(StepINColor.onPrimary.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: startInterview) {
                Text("Start Interview")
                    .font(StepINFont.button)
                    .foregroundColor(StepINColor.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(StepINColor.onPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: StepINRadius.medium, style: .continuous))
            }
            .buttonStyle(StepINPressStyle())
            .padding(.top, StepINSpacing.xs)
            .accessibilityLabel("Start Interview")
        }
        .padding(StepINSpacing.xl)
        .frame(maxWidth: .infinity)
        .background(StepINGradient.hero)
        .clipShape(RoundedRectangle(cornerRadius: StepINRadius.hero, style: .continuous))
        .stepINShadow(.card)
        .padding(.top, StepINSpacing.xs)
    }

    /// Haptic + wave animation, then open the interview flow.
    private func startInterview() {
        // Block re-entry while a one-shot is in progress.
        guard heroOneShot == nil || heroOneShot == .wakeUp else { return }
        startFeedbackTrigger.toggle()
        heroRobotState = .thinking
        heroOneShot = .wave
        // Wave is 12 frames @ 15fps = 0.8 s. Open the flow once it finishes.
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            showInterviewFlow = true
        }
    }

    // MARK: Recent interviews

    @ViewBuilder
    private var recentInterviewsSection: some View {
        VStack(alignment: .leading, spacing: StepINSpacing.md) {
            StepINSectionHeader(
                title: "Recent Interviews",
                actionTitle: completedInterviews.count > 2 ? "See All" : nil,
                action: completedInterviews.count > 2 ? { appState.selectedTab = .interviews } : nil
            )
            if recentInterviews.isEmpty {
                StepINCard {
                    StepINEmptyState(
                        title: "No interviews yet",
                        message: "Start your first interview and receive personalized feedback.",
                        actionTitle: "Start Interview",
                        action: startInterview
                    )
                }
            } else {
                ForEach(recentInterviews) { interview in
                    NavigationLink(value: interview.id) {
                        InterviewHistoryCard(interview: interview)
                    }
                    .buttonStyle(StepINPressStyle())
                }
            }
        }
    }

    // MARK: Recent goals

    @ViewBuilder
    private var recentGoalsSection: some View {
        if !recentGoals.isEmpty {
            VStack(alignment: .leading, spacing: StepINSpacing.md) {
                StepINSectionHeader(
                    title: "Recent Goals",
                    actionTitle: activeGoals.count > 3 ? "See All" : nil,
                    action: activeGoals.count > 3 ? { appState.selectedTab = .goals } : nil
                )
                StepINCard {
                    VStack(spacing: 0) {
                        ForEach(Array(recentGoals.enumerated()), id: \.element.id) { index, goal in
                            HomeGoalRow(goal: goal)
                            if index < recentGoals.count - 1 {
                                Divider()
                                    .background(StepINColor.divider)
                                    .padding(.vertical, StepINSpacing.sm)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Compact goal row for the Home dashboard.
private struct HomeGoalRow: View {
    let goal: AssignedGoal

    var body: some View {
        HStack(spacing: StepINSpacing.sm) {
            Image(systemName: goal.status == .completed ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22))
                .foregroundColor(goal.status == .completed ? StepINColor.success : StepINColor.textTertiary)

            VStack(alignment: .leading, spacing: 2) {
                Text(goal.title)
                    .font(StepINFont.body2)
                    .foregroundColor(StepINColor.textPrimary)
                    .lineLimit(2)
                Text(goal.homeSourceLabel)
                    .font(StepINFont.caption)
                    .foregroundColor(StepINColor.textTertiary)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

private extension AssignedGoal {
    /// "From UX Design Interview" format used on the Home dashboard.
    var homeSourceLabel: String {
        "From \(sourceJobTitle) Interview"
    }
}

#Preview("With data") {
    HomeView()
        .environment(AppState(hasProfile: true))
        .modelContainer(PreviewData.container)
}

#Preview("Empty") {
    HomeView()
        .environment(AppState(hasProfile: true))
        .modelContainer(PreviewData.emptyContainer)
}
