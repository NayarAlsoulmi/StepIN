//
//  InterviewsView.swift
//  StepIN
//
//  "My Interviews" — completed interview history, newest first.
//  Tap → Interview Details. Swipe → delete with confirmation.
//

import SwiftUI
import SwiftData

struct InterviewsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \InterviewRecord.startedAt, order: .reverse)
    private var interviews: [InterviewRecord]

    @State private var interviewPendingDeletion: InterviewRecord?

    private var completed: [InterviewRecord] {
        interviews.filter { $0.status == .completed }
    }

    var body: some View {
        NavigationStack {
            Group {
                if completed.isEmpty {
                    StepINEmptyState(
                        title: "No interviews yet",
                        message: "Your completed interviews and feedback will appear here.",
                        actionTitle: nil
                    )
                    .frame(maxHeight: .infinity)
                } else {
                    List {
                        ForEach(completed) { interview in
                            NavigationLink(value: interview.id) {
                                InterviewHistoryCard(interview: interview)
                            }
                            .buttonStyle(.plain)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(
                                top: StepINSpacing.xs,
                                leading: StepINSpacing.screenH,
                                bottom: StepINSpacing.xs,
                                trailing: StepINSpacing.screenH
                            ))
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    interviewPendingDeletion = interview
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(StepINColor.background)
            .navigationTitle("My Interviews")
            .navigationDestination(for: UUID.self) { id in
                if let interview = completed.first(where: { $0.id == id }) {
                    InterviewDetailsView(interview: interview)
                }
            }
            .confirmationDialog(
                "Delete this interview?",
                isPresented: Binding(
                    get: { interviewPendingDeletion != nil },
                    set: { if !$0 { interviewPendingDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete Interview", role: .destructive) {
                    if let interview = interviewPendingDeletion { delete(interview) }
                    interviewPendingDeletion = nil
                }
                Button("Cancel", role: .cancel) { interviewPendingDeletion = nil }
            } message: {
                Text("The transcript and analysis will be deleted. Goals from this interview are kept.")
            }
        }
    }

    /// Deletes the interview (transcript + analysis cascade). Goals are
    /// intentionally untouched. The interview's own CV copy is removed.
    private func delete(_ interview: InterviewRecord) {
        if let cvPath = interview.interviewCVLocalPath {
            CVDocumentService().deleteCV(atLocalPath: cvPath)
        }
        context.delete(interview)
    }
}

// MARK: - Shared card

/// Interview summary card used on Home and in My Interviews.
struct InterviewHistoryCard: View {
    let interview: InterviewRecord

    private var dateText: String {
        interview.startedAt.formatted(date: .abbreviated, time: .omitted)
    }

    var body: some View {
        StepINCard {
            HStack(spacing: StepINSpacing.md) {
                VStack(alignment: .leading, spacing: StepINSpacing.xxs) {
                    HStack(spacing: StepINSpacing.xs) {
                        Text(interview.jobTitle)
                            .font(StepINFont.h4)
                            .foregroundColor(StepINColor.textPrimary)
                        if interview.isPartial {
                            Text("Partial")
                                .font(StepINFont.body5)
                                .foregroundColor(StepINColor.warning)
                                .padding(.horizontal, StepINSpacing.xs)
                                .padding(.vertical, 2)
                                .background(StepINColor.warning.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }
                    if let company = interview.company {
                        Text(company)
                            .font(StepINFont.body3)
                            .foregroundColor(StepINColor.textSecondary)
                    }
                    Text(dateText)
                        .font(StepINFont.caption)
                        .foregroundColor(StepINColor.textTertiary)
                }
                Spacer()
                if let score = interview.overallScore {
                    ScoreBadge(score: score)
                }
            }
        }
    }
}

/// Compact circular score indicator.
struct ScoreBadge: View {
    let score: Int
    var size: CGFloat = 54

    private var lineWidth: CGFloat { size / 11 }

    var body: some View {
        ZStack {
            Circle()
                .stroke(StepINColor.primarySoft, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(score) / 100)
                .stroke(StepINColor.primary, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(score)")
                .font(.system(size: size * 0.3, weight: .bold))
                .foregroundColor(StepINColor.textPrimary)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Overall score \(score) out of 100")
    }
}

#Preview {
    InterviewsView()
        .modelContainer(PreviewData.container)
}
