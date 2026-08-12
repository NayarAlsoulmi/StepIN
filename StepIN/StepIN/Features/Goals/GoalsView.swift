//
//  GoalsView.swift
//  StepIN
//
//  "My Goals" — auto-assigned improvement goals. Incomplete first, then
//  completed. Completed remain visible until deleted.
//

import SwiftUI
import SwiftData

struct GoalsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Query(sort: \AssignedGoal.createdAt, order: .reverse)
    private var allGoals: [AssignedGoal]
    @Query(sort: \InterviewRecord.startedAt, order: .reverse)
    private var allInterviews: [InterviewRecord]

    @AppStorage(TutorialManager.goalsTutorialCompletedKey) private var hasCompletedGoalsTutorial = false
    @AppStorage(TutorialManager.interviewsTutorialResumeAtLastStepKey) private var shouldResumeInterviewsTutorialAtLastStep = false
    @State private var goalPendingDeletion: AssignedGoal?
    @State private var goalSourceDestination: InterviewRecord?
    @State private var searchText = ""
    @State private var tutorialManager = TutorialManager(
        steps: GoalsTutorial.steps(hasGoals: false),
        completionKey: TutorialManager.goalsTutorialCompletedKey
    )

    /// Non-deleted goals, incomplete first then completed.
    private var goals: [AssignedGoal] {
        allGoals
            .filter { $0.status != .deleted }
            .sorted { lhs, rhs in
                if (lhs.status == .completed) != (rhs.status == .completed) {
                    return lhs.status != .completed
                }
                return lhs.createdAt > rhs.createdAt
            }
    }

    private var filteredGoals: [AssignedGoal] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return goals }

        return goals.filter { goal in
            goalSearchText(for: goal).localizedCaseInsensitiveContains(query)
        }
    }

    private func goalSearchText(for goal: AssignedGoal) -> String {
        [goal.title, goal.sourceLabel]
            .joined(separator: " ")
    }

    var body: some View {
        TutorialHost(
            manager: tutorialManager,
            onBack: goBackInTutorial,
            canGoBackToPreviousPage: true
        ) {
            NavigationStack {
                VStack(alignment: .leading, spacing: StepINSpacing.md) {
                Text("My Goals")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundColor(StepINColor.textPrimary)
                    .padding(.horizontal, StepINSpacing.screenH)
                    .padding(.top, StepINSpacing.xxl)

                if !goals.isEmpty {
                    GoalsSearchBar(text: $searchText)
                        .padding(.horizontal, StepINSpacing.screenH)
                        .tutorialTarget(.goalsSearch)
                }

                if goals.isEmpty {
                    StepINEmptyState(
                        title: "No goals yet",
                        message: "Complete an interview to receive personalized improvement goals.",
                        actionTitle: nil
                    )
                    .frame(maxHeight: .infinity)
                    .tutorialTarget(.goalsEmptyState)
                } else {
                    ScrollView {
                        LazyVStack(spacing: StepINSpacing.sm) {
                            ForEach(filteredGoals) { goal in
                                GoalCard(
                                    goal: goal,
                                    onToggle: { toggle(goal) },
                                    onDelete: { goalPendingDeletion = goal },
                                    onSourceTap: allInterviews.first(where: { $0.id == goal.interviewID })
                                        .map { interview in { goalSourceDestination = interview } }
                                )
                            }
                        }
                        .padding(.horizontal, StepINSpacing.screenH)
                        .padding(.top, StepINSpacing.sm)
                        .padding(.bottom, StepINSpacing.giant)
                    }
                    .overlay {
                        if filteredGoals.isEmpty {
                            ContentUnavailableView.search(text: searchText)
                        }
                    }
                    .tutorialTarget(.goalsList)
                }
            }
            .background(StepINScreenBackground())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $goalSourceDestination) { interview in
                InterviewDetailsView(interview: interview)
            }
            .alert(
                "Delete this goal?",
                isPresented: Binding(
                    get: { goalPendingDeletion != nil },
                    set: { if !$0 { goalPendingDeletion = nil } }
                )
            ) {
                Button("Delete", role: .destructive) {
                    if let goal = goalPendingDeletion { delete(goal) }
                    goalPendingDeletion = nil
                }
                Button("Cancel", role: .cancel) { goalPendingDeletion = nil }
            }
            .tint(StepINColor.textPrimary.opacity(0.72))
            }
        }
        .onAppear(perform: startTutorialIfNeeded)
    }

    private func startTutorialIfNeeded() {
        tutorialManager.updateSteps(GoalsTutorial.steps(hasGoals: !goals.isEmpty))

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard appState.selectedTab == .goals else { return }
            tutorialManager.startIfNeeded(hasCompletedTutorial: hasCompletedGoalsTutorial)
        }
    }

    private func goBackInTutorial() {
        if tutorialManager.isFirstStep {
            tutorialManager.dismissWithoutCompleting()
            hasCompletedGoalsTutorial = false
            shouldResumeInterviewsTutorialAtLastStep = true
            appState.selectedTab = .interviews
        } else {
            tutorialManager.back()
        }
    }

    private func toggle(_ goal: AssignedGoal) {
        withAnimation(StepINMotion.springStandard) {
            if goal.status == .completed {
                goal.status = .toDo
                goal.completedAt = nil
            } else {
                goal.status = .completed
                goal.completedAt = .now
            }
        }
    }

    private func delete(_ goal: AssignedGoal) {
        withAnimation(StepINMotion.springStandard) {
            goal.status = .deleted // soft deletion
        }
    }
}

private struct GoalsSearchBar: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: StepINSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(StepINColor.textTertiary)

            TextField("Search goals", text: $text)
                .font(StepINFont.bodyRegular)
                .foregroundColor(StepINColor.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(StepINColor.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, StepINSpacing.md)
        .frame(height: 46)
        .background(Color.white.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: StepINRadius.medium, style: .continuous))
    }
}

// MARK: - Goal card

struct GoalCard: View {
    let goal: AssignedGoal
    let onToggle: () -> Void
    let onDelete: () -> Void
    var onSourceTap: (() -> Void)? = nil

    private var isCompleted: Bool { goal.status == .completed }

    var body: some View {
        StepINCard(padding: StepINSpacing.sm) {
            HStack(alignment: .top, spacing: StepINSpacing.sm) {
                Button(action: onToggle) {
                    Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundColor(isCompleted ? StepINColor.success : StepINColor.textTertiary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isCompleted ? "Mark goal as to do" : "Mark goal as completed")
                .tutorialTarget(.goalToggle)

                VStack(alignment: .leading, spacing: StepINSpacing.xs) {
                    Text(goal.title)
                        .font(StepINFont.body2)
                        .foregroundStyle(StepINColor.textPrimary)
                        .strikethrough(isCompleted, color: StepINColor.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    sourceRow
                }
                .opacity(isCompleted ? 0.6 : 1)

                Spacer(minLength: StepINSpacing.xs)

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundColor(StepINColor.textTertiary)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete goal")
            }
        }
    }

    @ViewBuilder
    private var sourceRowContent: some View {
        Image(systemName: "waveform")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(StepINColor.primary.opacity(0.85))
            .frame(width: 18, height: 18)
            .background(StepINColor.primarySoft.opacity(0.65), in: Circle())
        Text(goal.sourceLabel)
            .font(StepINFont.caption)
            .foregroundStyle(StepINColor.textTertiary)
            .lineLimit(1)
        if onSourceTap != nil {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(StepINColor.textTertiary)
        }
    }

    @ViewBuilder
    private var sourceRow: some View {
        if let onSourceTap {
            Button(action: onSourceTap) {
                HStack(spacing: StepINSpacing.xs) { sourceRowContent }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open source interview: \(goal.sourceLabel)")
        } else {
            HStack(spacing: StepINSpacing.xs) { sourceRowContent }
        }
    }

}

#Preview {
    GoalsView()
        .modelContainer(PreviewData.container)
}
