//
//  InterviewDetailsView.swift
//  StepIN
//
//  Saved interview: summary header + segmented Analysis / Chat History.
//  Chat History is transcript-only — no scores, no inline coaching.
//

import SwiftUI
import SwiftData

struct InterviewDetailsView: View {
    let interview: InterviewRecord

    @Query private var allGoals: [AssignedGoal]
    @State private var segment: Segment

    init(interview: InterviewRecord, initialSegment: Segment = .analysis) {
        self.interview = interview
        _segment = State(initialValue: initialSegment)
    }

    enum Segment: String, CaseIterable {
        case analysis = "Analysis"
        case chat = "Chat History"
    }

    private var goals: [AssignedGoal] {
        allGoals.filter { $0.interviewID == interview.id && $0.status != .deleted }
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

    var body: some View {
        ScrollView {
            VStack(spacing: StepINSpacing.xl) {
                summaryHeader

                Picker("Section", selection: $segment) {
                    ForEach(Segment.allCases, id: \.self) { segment in
                        Text(segment.rawValue).tag(segment)
                    }
                }
                .pickerStyle(.segmented)

                switch segment {
                case .analysis: analysisSection
                case .chat: chatSection
                }
            }
            .padding(StepINSpacing.screenH)
            .padding(.bottom, StepINSpacing.xxl)
        }
        .background(StepINScreenBackground())
        .navigationTitle(interview.jobTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
        
        // MARK: Summary
        
        private var summaryHeader: some View {
            StepINCard(padding: StepINSpacing.lg) {
                HStack(alignment: .center, spacing: StepINSpacing.md) {
                    VStack(alignment: .leading, spacing: StepINSpacing.xs) {
                        Text(interview.jobTitle)
                            .font(StepINFont.h2)
                            .foregroundColor(StepINColor.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let company = interview.company {
                            Text(company)
                                .font(StepINFont.body2)
                                .foregroundColor(StepINColor.textSecondary)
                        }
                        Text(interview.startedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(StepINFont.caption)
                            .foregroundColor(StepINColor.textTertiary)
                        if interview.isPartial {
                            Text("Partial")
                                .font(StepINFont.body5)
                                .foregroundColor(StepINColor.warning)
                                .padding(.horizontal, StepINSpacing.xs)
                                .padding(.vertical, 2)
                                .background(StepINColor.warning.opacity(0.15))
                                .clipShape(Capsule())
                                .padding(.top, StepINSpacing.xxs)
                        }
                    }
                    Spacer(minLength: StepINSpacing.md)
                    if let score = interview.overallScore {
                        ScoreBadge(score: score, size: 72)
                    }
                }
            }
        }
    

    // MARK: Analysis

    @ViewBuilder
    private var analysisSection: some View {
        if let analysis = interview.analysis {
            VStack(alignment: .leading, spacing: StepINSpacing.xl) {
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

                if !goals.isEmpty {
                    VStack(alignment: .leading, spacing: StepINSpacing.sm) {
                        StepINSectionHeader(title: "Assigned Goals")
                        ForEach(goals) { goal in
                            StepINCard {
                                HStack(spacing: StepINSpacing.sm) {
                                    Button { toggle(goal) } label: {
                                        Image(systemName: goal.status == .completed ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 22))
                                            .foregroundColor(goal.status == .completed ? StepINColor.success : StepINColor.textTertiary)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(goal.status == .completed ? "Mark goal as to do" : "Mark goal as completed")
                                    Text(goal.title)
                                        .font(StepINFont.body2)
                                        .foregroundColor(StepINColor.textPrimary)
                                }
                            }
                        }
                    }
                }
            }
        } else {
            StepINEmptyState(
                title: "Analysis unavailable",
                message: "This interview doesn't have an analysis yet."
            )
        }
    }

    // MARK: Chat history (transcript only)

    @ViewBuilder
    private var chatSection: some View {
        let messages = interview.visibleTranscript
        if messages.isEmpty {
            StepINEmptyState(
                title: "No transcript",
                message: "This interview has no recorded conversation."
            )
        } else {
            VStack(spacing: StepINSpacing.md) {
                ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                    // Robot thumbnail only at the start of an interviewer
                    // turn, so the transcript never feels crowded.
                    TranscriptRow(
                        message: message,
                        showsRobotThumbnail: message.speaker == .interviewer
                            && (index == 0 || messages[index - 1].speaker != .interviewer)
                    )
                }
            }
        }
    }
}

// MARK: - Components

struct PerformanceMetricRow: View {
    let category: PerformanceCategory
    let score: Int

    var body: some View {
        VStack(alignment: .leading, spacing: StepINSpacing.xxs) {
            HStack {
                Text(category.rawValue)
                    .font(StepINFont.body3)
                    .foregroundColor(StepINColor.textPrimary)
                Spacer()
                Text("\(score)")
                    .font(StepINFont.body3)
                    .foregroundColor(StepINColor.textSecondary)
            }
            ProgressView(value: Double(score), total: 100)
                .tint(StepINColor.primary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(category.rawValue): \(score) out of 100")
    }
}

struct FeedbackListSection: View {
    let title: String
    let items: [String]
    let icon: String
    let iconColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: StepINSpacing.sm) {
            StepINSectionHeader(title: title)
            StepINCard {
                VStack(alignment: .leading, spacing: StepINSpacing.md) {
                    ForEach(items, id: \.self) { item in
                        HStack(alignment: .top, spacing: StepINSpacing.sm) {
                            Image(systemName: icon)
                                .foregroundColor(iconColor)
                                .font(.system(size: 16))
                                .padding(.top, 2)
                            Text(item)
                                .font(StepINFont.bodyRegular)
                                .foregroundColor(StepINColor.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}

/// Transcript bubble: interviewer on the left in a soft neutral bubble, the
/// candidate on the right in brand purple. This is an interview transcript,
/// not a chat app — no timestamps, no metadata.
struct TranscriptRow: View {
    let message: InterviewMessage
    /// Small official StepINRobot thumbnail beside the bubble; shown only
    /// on the first message of an interviewer turn.
    var showsRobotThumbnail: Bool = false

    private var isInterviewer: Bool { message.speaker == .interviewer }
    private let thumbnailSize: CGFloat = 24

    var body: some View {
        HStack(alignment: .bottom, spacing: StepINSpacing.xs) {
            if !isInterviewer { Spacer(minLength: StepINSpacing.huge) }

            if isInterviewer {
                if showsRobotThumbnail {
                    Image("StepINRobot")
                        .resizable()
                        .scaledToFit()
                        .frame(width: thumbnailSize, height: thumbnailSize)
                        .accessibilityHidden(true)
                } else {
                    // Keep bubbles of the same turn left-aligned.
                    Color.clear.frame(width: thumbnailSize, height: 1)
                }
            }

            Text(message.text)
                .font(.system(size: 15, design: .rounded))
                .foregroundColor(isInterviewer ? StepINColor.textPrimary : StepINColor.onPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, StepINSpacing.md)
                .padding(.vertical, 10)
                .background(isInterviewer ? StepINColor.backgroundSecondary : StepINColor.primary)
                .clipShape(RoundedRectangle(cornerRadius: StepINRadius.medium + 2, style: .continuous))

            if isInterviewer { Spacer(minLength: StepINSpacing.huge) }
        }
        .accessibilityElement()
        .accessibilityLabel("\(isInterviewer ? "Interviewer" : "You"): \(message.text)")
    }
}

#Preview("Analysis") {
    let container = PreviewData.container
    let interview = try! container.mainContext.fetch(FetchDescriptor<InterviewRecord>()).first!
    return NavigationStack {
        InterviewDetailsView(interview: interview)
    }
    .modelContainer(container)
}

#Preview("Chat History") {
    let container = PreviewData.container
    let interview = try! container.mainContext.fetch(FetchDescriptor<InterviewRecord>()).first!
    return NavigationStack {
        InterviewDetailsView(interview: interview, initialSegment: .chat)
    }
    .modelContainer(container)
}
