//
//  InterviewsView.swift
//  StepIN
//
//  "My Interviews" — completed interview history, newest first.
//  Tap → Interview Details. Swipe → delete with confirmation.
//

import SwiftUI
import SwiftData

private enum InterviewHistoryFilter: Hashable, CaseIterable, Identifiable {
    case completed
    case partial

    var id: Self { self }

    var title: String {
        switch self {
        case .completed: "Completed"
        case .partial: "Partial"
        }
    }

    func matches(_ interview: InterviewRecord) -> Bool {
        switch self {
        case .completed:
            interview.status == .completed && !interview.isPartial
        case .partial:
            interview.isPartial
        }
    }
}

struct InterviewsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Query(sort: \InterviewRecord.startedAt, order: .reverse)
    private var interviews: [InterviewRecord]

    @AppStorage(TutorialManager.interviewsTutorialCompletedKey) private var hasCompletedInterviewsTutorial = false
    @AppStorage(TutorialManager.interviewsTutorialResumeAtLastStepKey) private var shouldResumeInterviewsTutorialAtLastStep = false
    @AppStorage(TutorialManager.homeTutorialResumeAtLastStepKey) private var shouldResumeHomeTutorialAtLastStep = false
    @State private var interviewPendingDeletion: InterviewRecord?
    @State private var selectedInterviewID: UUID?
    @State private var searchText = ""
    @State private var selectedFilter: InterviewHistoryFilter = .completed
    @State private var tutorialManager = TutorialManager(
        steps: InterviewsTutorial.steps(hasCompletedInterviews: false),
        completionKey: TutorialManager.interviewsTutorialCompletedKey
    )

    private var filteredByStatus: [InterviewRecord] {
        interviews.filter { selectedFilter.matches($0) }
    }

    private var filtered: [InterviewRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return filteredByStatus }

        return filteredByStatus.filter { interview in
            cardSearchText(for: interview).localizedCaseInsensitiveContains(query)
        }
    }

    private var filterItems: [InterviewHistoryFilter] {
        InterviewHistoryFilter.allCases
    }

    private func cardSearchText(for interview: InterviewRecord) -> String {
        [
            interview.jobTitle,
            interview.company,
            interview.startedAt.formatted(date: .abbreviated, time: .omitted),
            interview.overallScore.map(String.init),
            interview.isPartial ? "Partial" : interview.status.displayName
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }

    var body: some View {
        TutorialHost(
            manager: tutorialManager,
            onBack: goBackInTutorial,
            advancesToAnotherPage: true,
            canGoBackToPreviousPage: true
        ) {
            NavigationStack {
                VStack(alignment: .leading, spacing: StepINSpacing.md) {
                Text("My Interviews")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundColor(StepINColor.textPrimary)
                    .padding(.horizontal, StepINSpacing.screenH)
                    .padding(.top, StepINSpacing.xxl)

                if !interviews.isEmpty {
                    InterviewSearchBar(text: $searchText)
                        .padding(.horizontal, StepINSpacing.screenH)
                        .tutorialTarget(.interviewsSearch)

                    InterviewStatusFilterBar(
                        filters: filterItems,
                        selection: $selectedFilter
                    )
                    .padding(.horizontal, StepINSpacing.screenH)
                }

                if interviews.isEmpty {
                    StepINEmptyState(
                        title: "No interviews yet",
                        message: "Your interviews and feedback will appear here.",
                        actionTitle: nil
                    )
                    .frame(maxHeight: .infinity)
                    .tutorialTarget(.interviewsEmptyState)
                } else {
                    List {
                        ForEach(filtered) { interview in
                            Button {
                                selectedInterviewID = interview.id
                            } label: {
                                InterviewHistoryCard(interview: interview, showsChevron: true)
                                    .contentShape(Rectangle())
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
                    .contentMargins(.top, StepINSpacing.xs, for: .scrollContent)
                    .contentMargins(.bottom, StepINSpacing.giant, for: .scrollContent)
                    .overlay {
                        if filtered.isEmpty {
                            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                ContentUnavailableView(
                                    "No \(selectedFilter.title.lowercased()) interviews",
                                    systemImage: "tray",
                                    description: Text("Try another interview status filter.")
                                )
                            } else {
                                ContentUnavailableView.search(text: searchText)
                            }
                        }
                    }
                    .tutorialTarget(.interviewsList)
                }
            }
            .background(StepINScreenBackground())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $selectedInterviewID) { id in
                if let interview = interviews.first(where: { $0.id == id }) {
                    InterviewDetailsView(interview: interview)
                }
            }
            .alert(
                "Delete this interview?",
                isPresented: Binding(
                    get: { interviewPendingDeletion != nil },
                    set: { if !$0 { interviewPendingDeletion = nil } }
                )
            ) {
                Button("Delete Interview", role: .destructive) {
                    if let interview = interviewPendingDeletion { delete(interview) }
                    interviewPendingDeletion = nil
                }
                Button("Cancel", role: .cancel) { interviewPendingDeletion = nil }
            } message: {
                Text("The transcript and analysis will be deleted. Goals from this interview are kept.")
            }
            .tint(StepINColor.textPrimary.opacity(0.72))
            }
        }
        .onAppear(perform: startTutorialIfNeeded)
    }

    private func startTutorialIfNeeded() {
        tutorialManager.updateSteps(InterviewsTutorial.steps(hasCompletedInterviews: !interviews.isEmpty))
        tutorialManager.onFinish = {
            appState.selectedTab = .goals
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard appState.selectedTab == .interviews else { return }
            if shouldResumeInterviewsTutorialAtLastStep {
                shouldResumeInterviewsTutorialAtLastStep = false
                tutorialManager.startAtLastStep()
            } else {
                tutorialManager.startIfNeeded(hasCompletedTutorial: hasCompletedInterviewsTutorial)
            }
        }
    }

    private func goBackInTutorial() {
        if tutorialManager.isFirstStep {
            tutorialManager.dismissWithoutCompleting()
            hasCompletedInterviewsTutorial = false
            shouldResumeHomeTutorialAtLastStep = true
            appState.selectedTab = .home
        } else {
            tutorialManager.back()
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

private struct InterviewStatusFilterBar: View {
    let filters: [InterviewHistoryFilter]
    @Binding var selection: InterviewHistoryFilter

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: StepINSpacing.xs) {
                ForEach(filters) { filter in
                    Button {
                        withAnimation(StepINMotion.springSnappy) {
                            selection = filter
                        }
                    } label: {
                        Text(filter.title)
                            .font(StepINFont.body3.weight(.semibold))
                            .foregroundColor(selection == filter ? StepINColor.onPrimary : StepINColor.textSecondary)
                            .padding(.horizontal, StepINSpacing.sm)
                            .frame(height: 36)
                            .background(selection == filter ? StepINColor.primary : Color.white.opacity(0.72))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(filter.title)
                }
            }
        }
    }
}

private struct InterviewSearchBar: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: StepINSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(StepINColor.textTertiary)

            TextField("Search interviews", text: $text)
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

// MARK: - Shared card

/// Interview summary card used on Home and in My Interviews.
struct InterviewHistoryCard: View {
    let interview: InterviewRecord
    var showsChevron = false

    private var dateText: String {
        interview.startedAt.formatted(date: .abbreviated, time: .omitted)
    }

    private var statusBadge: (title: String, color: Color)? {
        if interview.isPartial {
            return ("Partial", StepINColor.warning)
        }
        guard interview.status != .completed else { return nil }
        return (interview.status.displayName, interview.status.badgeColor)
    }

    var body: some View {
        StepINCard {
            HStack(spacing: StepINSpacing.md) {
                VStack(alignment: .leading, spacing: StepINSpacing.xxs) {
                    HStack(spacing: StepINSpacing.xs) {
                        Text(interview.jobTitle)
                            .font(StepINFont.h4)
                            .foregroundColor(StepINColor.textPrimary)
                        if let statusBadge {
                            Text(statusBadge.title)
                                .font(StepINFont.body5)
                                .foregroundColor(statusBadge.color)
                                .padding(.horizontal, StepINSpacing.xs)
                                .padding(.vertical, 2)
                                .background(statusBadge.color.opacity(0.15))
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
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(StepINColor.textTertiary)
                }
            }
        }
    }
}

/// Compact circular score indicator. The ring fills from zero once, the
/// first time the badge appears.
private extension InterviewStatus {
    var displayName: String {
        switch self {
        case .draft: "Draft"
        case .preparing: "Preparing"
        case .inProgress: "In Progress"
        case .paused: "Paused"
        case .analyzing: "Analyzing"
        case .completed: "Completed"
        case .failed: "Failed"
        }
    }

    var badgeColor: Color {
        switch self {
        case .completed:
            StepINColor.success
        case .failed:
            StepINColor.error
        case .analyzing, .preparing, .inProgress:
            StepINColor.info
        case .paused, .draft:
            StepINColor.textTertiary
        }
    }
}

struct ScoreBadge: View {
    let score: Int
    var size: CGFloat = 54

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ringProgress: CGFloat = 0

    private var lineWidth: CGFloat { size / 11 }

    var body: some View {
        ZStack {
            Circle()
                .stroke(StepINColor.primarySoft, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: ringProgress)
                .stroke(StepINColor.primary, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(score)")
                .font(.system(size: size * 0.3, weight: .bold, design: .rounded))
                .foregroundColor(StepINColor.textPrimary)
        }
        .frame(width: size, height: size)
        .onAppear {
            // Animate only on first appearance; re-appearing rows keep
            // their filled ring.
            guard ringProgress == 0 else { return }
            let target = CGFloat(score) / 100
            if reduceMotion {
                ringProgress = target
            } else {
                withAnimation(.easeOut(duration: 0.7)) { ringProgress = target }
            }
        }
        .accessibilityLabel("Overall score \(score) out of 100")
    }
}

#Preview {
    InterviewsView()
        .modelContainer(PreviewData.container)
}
