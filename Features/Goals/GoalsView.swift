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
    @Environment(\.modelContext) private var context
    @Query(sort: \AssignedGoal.createdAt, order: .reverse)
    private var allGoals: [AssignedGoal]

    @State private var goalPendingDeletion: AssignedGoal?

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

    var body: some View {
        NavigationStack {
            Group {
                if goals.isEmpty {
                    StepINEmptyState(
                        title: "No goals yet",
                        message: "Complete an interview to receive personalized improvement goals.",
                        actionTitle: nil
                    )
                    .frame(maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: StepINSpacing.md) {
                            ForEach(goals) { goal in
                                GoalCard(
                                    goal: goal,
                                    onToggle: { toggle(goal) },
                                    onDelete: { goalPendingDeletion = goal }
                                )
                            }
                        }
                        .padding(StepINSpacing.screenH)
                    }
                }
            }
            .background(StepINScreenBackground())
            .navigationTitle("My Goals")
            .confirmationDialog(
                "Delete this goal?",
                isPresented: Binding(
                    get: { goalPendingDeletion != nil },
                    set: { if !$0 { goalPendingDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let goal = goalPendingDeletion { delete(goal) }
                    goalPendingDeletion = nil
                }
                Button("Cancel", role: .cancel) { goalPendingDeletion = nil }
            }
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

// MARK: - Goal card

struct GoalCard: View {
    let goal: AssignedGoal
    let onToggle: () -> Void
    let onDelete: () -> Void

    private var isCompleted: Bool { goal.status == .completed }

    var body: some View {
        StepINCard {
            HStack(alignment: .top, spacing: StepINSpacing.md) {
                Button(action: onToggle) {
                    Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 24))
                        .foregroundColor(isCompleted ? StepINColor.success : StepINColor.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isCompleted ? "Mark goal as to do" : "Mark goal as completed")

                VStack(alignment: .leading, spacing: StepINSpacing.xxs) {
                    Text(goal.title)
                        .font(StepINFont.body1)
                        .foregroundColor(StepINColor.textPrimary)
                        .strikethrough(isCompleted, color: StepINColor.textTertiary)
                    Text(goal.sourceLabel)
                        .font(StepINFont.caption)
                        .foregroundColor(StepINColor.textTertiary)
                }
                .opacity(isCompleted ? 0.6 : 1)

                Spacer(minLength: 0)

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundColor(StepINColor.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete goal")
            }
        }
    }

}

#Preview {
    GoalsView()
        .modelContainer(PreviewData.container)
}
