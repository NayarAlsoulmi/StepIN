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
                        LazyVStack(spacing: StepINSpacing.sm) {
                            ForEach(goals) { goal in
                                GoalCard(
                                    goal: goal,
                                    onToggle: { toggle(goal) },
                                    onDelete: { goalPendingDeletion = goal }
                                )
                            }
                        }
                        .padding(.horizontal, StepINSpacing.screenH)
                        .padding(.top, StepINSpacing.sm)
                        .padding(.bottom, StepINSpacing.giant)
                    }
                }
            }
            .background(StepINScreenBackground())
            .navigationTitle("My Goals")
            .navigationBarTitleDisplayMode(.large)
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

                VStack(alignment: .leading, spacing: StepINSpacing.xs) {
                    Text(goal.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(StepINColor.textPrimary)
                        .strikethrough(isCompleted, color: StepINColor.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: StepINSpacing.xs) {
                        Image(systemName: "waveform")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(StepINColor.primary.opacity(0.85))
                            .frame(width: 18, height: 18)
                            .background(StepINColor.primarySoft.opacity(0.65), in: Circle())

                        Text(goal.sourceLabel)
                            .font(.footnote)
                            .foregroundStyle(StepINColor.textTertiary)
                            .lineLimit(1)
                    }
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

}

#Preview {
    GoalsView()
        .modelContainer(PreviewData.container)
}
