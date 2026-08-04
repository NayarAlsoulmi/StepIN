//
//  ResultsView.swift
//  StepIN
//
//  Final results, in the spec's order: Overall Score → Performance →
//  Strengths → Areas to Improve → Assigned Goals → Practice Again →
//  Return Home. The interview is already saved before this screen appears.
//

import SwiftUI
import SwiftData

struct ResultsView: View {
    let interview: InterviewRecord
    let goals: [AssignedGoal]
    let onPracticeAgain: () -> Void
    let onReturnHome: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ringProgress: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(spacing: StepINSpacing.xl) {
                overallScore

                if let analysis = interview.analysis {
                    VStack(alignment: .leading, spacing: StepINSpacing.sm) {
                        StepINSectionHeader(title: "Performance")
                        StepINCard {
                            VStack(spacing: StepINSpacing.md) {
                                ForEach(analysis.categoryScores, id: \.category) { item in
                                    PerformanceMetricRow(category: item.category, score: item.score)
                                }
                            }
                        }
                    }

                    FeedbackListSection(
                        title: "Strengths",
                        items: analysis.strengths,
                        icon: "checkmark.circle.fill",
                        iconColor: StepINColor.success
                    )

                    FeedbackListSection(
                        title: "Areas to Improve",
                        items: analysis.areasToImprove,
                        icon: "arrow.up.forward.circle.fill",
                        iconColor: StepINColor.primary
                    )
                }

                if !goals.isEmpty {
                    VStack(alignment: .leading, spacing: StepINSpacing.sm) {
                        StepINSectionHeader(title: "Assigned Goals")
                        ForEach(goals) { goal in
                            StepINCard {
                                HStack(spacing: StepINSpacing.sm) {
                                    Image(systemName: "target")
                                        .foregroundColor(StepINColor.primary)
                                    Text(goal.title)
                                        .font(StepINFont.body2)
                                        .foregroundColor(StepINColor.textPrimary)
                                }
                            }
                        }
                    }
                }

                VStack(spacing: StepINSpacing.sm) {
                    StepINPrimaryButton(title: "Practice Again", action: onPracticeAgain)
                    StepINSecondaryButton(title: "Return Home", action: onReturnHome)
                }
                .padding(.top, StepINSpacing.xs)
            }
            .padding(StepINSpacing.screenH)
            .padding(.bottom, StepINSpacing.xxl)
        }
        .background(StepINColor.background)
    }

    private var overallScore: some View {
        VStack(spacing: StepINSpacing.md) {
            if interview.isPartial {
                Text("Partial Interview")
                    .font(StepINFont.body4)
                    .foregroundColor(StepINColor.warning)
                    .padding(.horizontal, StepINSpacing.sm)
                    .padding(.vertical, 4)
                    .background(StepINColor.warning.opacity(0.15))
                    .clipShape(Capsule())
            }

            ZStack {
                Circle()
                    .stroke(StepINColor.primarySoft, lineWidth: 12)
                Circle()
                    .trim(from: 0, to: ringProgress)
                    .stroke(StepINColor.primary, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 2) {
                    Text("\(interview.overallScore ?? 0)")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundColor(StepINColor.textPrimary)
                    Text("/ 100")
                        .font(StepINFont.body3)
                        .foregroundColor(StepINColor.textSecondary)
                }
            }
            .frame(width: 150, height: 150)
            .accessibilityElement()
            .accessibilityLabel("Overall score \(interview.overallScore ?? 0) out of 100")
            .onAppear {
                let target = CGFloat(interview.overallScore ?? 0) / 100
                if reduceMotion {
                    ringProgress = target
                } else {
                    withAnimation(.easeOut(duration: 0.9)) { ringProgress = target }
                }
            }
        }
        .padding(.top, StepINSpacing.lg)
    }
}

#Preview {
    let container = PreviewData.container
    let interview = try! container.mainContext.fetch(FetchDescriptor<InterviewRecord>()).first!
    let goals = try! container.mainContext.fetch(FetchDescriptor<AssignedGoal>())
    return NavigationStack {
        ResultsView(
            interview: interview,
            goals: goals,
            onPracticeAgain: {},
            onReturnHome: {}
        )
        .navigationTitle("Your Results")
        .navigationBarTitleDisplayMode(.inline)
    }
    .modelContainer(container)
}
