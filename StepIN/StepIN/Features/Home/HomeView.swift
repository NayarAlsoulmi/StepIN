//
//  HomeView.swift
//  StepIN
//
//  Home surface:
//  - Compact personalized header
//  - Purple interview hero card with Robert on the right
//  - Idle breathing/sway via repeatForever, gated for Preview stability
//

import SwiftUI
import SwiftData
import UIKit

struct HomeView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(StepINNavigationBridge.startInterviewRequestIDKey) private var startInterviewRequestID = ""
    @AppStorage(TutorialManager.homeTutorialCompletedKey) private var hasCompletedHomeTutorial = false
    @AppStorage(TutorialManager.homeTutorialResumeAtLastStepKey) private var shouldResumeHomeTutorialAtLastStep = false
    @Query private var profiles: [UserProfile]
    @Query(sort: \InterviewRecord.startedAt, order: .reverse)
    private var interviews: [InterviewRecord]
    @Query(sort: \AssignedGoal.createdAt, order: .reverse)
    private var allGoals: [AssignedGoal]

    @State private var showInterviewFlow = false
    @State private var isStartingInterview = false
    @State private var heroRobotState: RobotState = .idle
    @State private var heroOneShot: RobertAnimationState? = nil
    @State private var startFeedbackTrigger = false
    @State private var robertTapTrigger = false
    @State private var pendingHeroWaves = 0
    @State private var showProfile = false
    @State private var tutorialManager = TutorialManager(steps: HomeTutorial.steps)

    // Entry — 0 → 1 drives opacity, scale, and vertical offset together
    @State private var robertAppeared: Double = 0

    // Idle overlays — smoothly reset when a one-shot begins
    @State private var breatheY: Double = 0
    @State private var swayAngle: Double = 0

    // Session-level; survives tab switches
    nonisolated(unsafe) private static var hasPlayedRobertGreeting = false

    private var firstName: String { profiles.first?.firstName ?? "there" }
    private var profileImage: UIImage? {
        ProfileImageService.image(atLocalPath: profiles.first?.profileImageLocalPath)
    }

    private var userInitials: String {
        let f = profiles.first?.firstName.prefix(1) ?? "?"
        let l = profiles.first?.lastName?.prefix(1) ?? ""
        return "\(f)\(l)".uppercased()
    }

    private var completedInterviews: [InterviewRecord] { interviews.filter { $0.status == .completed } }
    private var recentInterviews:    [InterviewRecord] { Array(completedInterviews.prefix(2)) }
    private var activeGoals:         [AssignedGoal]    { allGoals.filter { $0.status == .toDo } }
    private var recentGoals:         [AssignedGoal]    { Array(activeGoals.prefix(3)) }

    private var isHeroIdle: Bool {
        heroOneShot == nil && pendingHeroWaves == 0 && heroRobotState == .idle
    }

    // MARK: Body

    var body: some View {
        TutorialHost(manager: tutorialManager, advancesToAnotherPage: true) {
            NavigationStack {
                VStack(spacing: 0) {
                    headerView
                        .padding(.horizontal, StepINSpacing.screenH)
                        .padding(.bottom, StepINSpacing.section)
                    ScrollView {
                        VStack(alignment: .leading, spacing: StepINSpacing.section) {
                            heroCard
                            recentInterviewsSection
                            recentGoalsSection
                        }
                        .padding(.horizontal, StepINSpacing.screenH)
                        .padding(.bottom, StepINSpacing.xxl)
                    }
                }
                .background(StepINScreenBackground())
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: UUID.self) { id in
                    if let interview = interviews.first(where: { $0.id == id }) {
                        InterviewDetailsView(interview: interview)
                    }
                }
                .sensoryFeedback(.impact(weight: .light), trigger: startFeedbackTrigger)
                .sensoryFeedback(.impact(weight: .light), trigger: robertTapTrigger)
                .fullScreenCover(isPresented: $showProfile) {
                    NavigationStack {
                        ProfileView(embedsInNavigationStack: false)
                            .toolbar(.visible, for: .navigationBar)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("Close") {
                                        showProfile = false
                                    }
                                    .foregroundStyle(StepINColor.primary)
                                }
                            }
                    }
                }
                .fullScreenCover(isPresented: $showInterviewFlow) {
                    InterviewFlowView {
                        showInterviewFlow = false
                        isStartingInterview = false
                        heroRobotState = .idle
                    }
                }
            }
        }
        .onAppear {
            triggerHomeEntry()
            routePendingStartInterviewIfNeeded()
            startHomeTutorialIfNeeded()
        }
        .onChange(of: startInterviewRequestID) { _, _ in
            routePendingStartInterviewIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: StepINNavigationBridge.startInterviewNotification)) { _ in
            routePendingStartInterviewIfNeeded()
        }
    }

    // MARK: Premium header

    private var headerView: some View {
        HomeGreetingHeader(
            firstName: firstName,
            initials: userInitials,
            profileImage: profileImage,
            profileAction: { showProfile = true }
        )
            .padding(.top, StepINSpacing.md)
    }

    // MARK: Hero card — horizontal split

    private var heroCard: some View {
        let appeared = robertAppeared
        let breathe  = breatheY
        let sway     = swayAngle

        return HomeInterviewHeroCard(
            appeared: appeared,
            breatheY: breathe,
            swayAngle: sway,
            robotState: heroRobotState,
            oneShot: heroOneShot,
            startAction: startInterview,
            robotTapAction: handleRobertTap,
            oneShotComplete: handleRobertOneShotComplete,
            isStartingInterview: isStartingInterview
        )
        .onChange(of: isHeroIdle) { _, idle in
            if idle { startIdleAnimations() } else { stopIdleAnimations() }
        }
    }

    // MARK: Entry + greeting

    private func triggerHomeEntry() {
        guard !reduceMotion else {
            robertAppeared = 1.0
            HomeView.hasPlayedRobertGreeting = true
            return
        }

        Task {
            try? await Task.sleep(for: .milliseconds(80))
            withAnimation(.spring(response: 0.52, dampingFraction: 0.78)) {
                robertAppeared = 1.0
            }
        }

        guard !HomeView.hasPlayedRobertGreeting else {
            startIdleAnimations()
            return
        }
        HomeView.hasPlayedRobertGreeting = true
        Task {
            try? await Task.sleep(for: .milliseconds(420))
            heroOneShot = .wakeUp
        }
    }

    // MARK: Idle animations

    private func startIdleAnimations() {
        guard !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 2.1).repeatForever(autoreverses: true)) {
            breatheY = -2
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            guard isHeroIdle else { return }
            withAnimation(.easeInOut(duration: 4.3).repeatForever(autoreverses: true)) {
                swayAngle = 0.65
            }
        }
    }

    private func stopIdleAnimations() {
        withAnimation(.easeOut(duration: 0.25)) {
            breatheY  = 0
            swayAngle = 0
        }
    }

    private func handleRobertTap() {
        guard !reduceMotion, heroOneShot == nil, pendingHeroWaves == 0 else { return }
        robertTapTrigger.toggle()
        pendingHeroWaves = 1
        heroOneShot = .wave
    }

    private func handleRobertOneShotComplete() {
        switch heroOneShot {
        case .wakeUp:
            pendingHeroWaves = 1
            heroOneShot = .wave
        case .wave:
            pendingHeroWaves = max(pendingHeroWaves - 1, 0)
            if pendingHeroWaves > 0 {
                heroOneShot = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                    guard pendingHeroWaves > 0 else { return }
                    heroOneShot = .wave
                }
            } else {
                heroOneShot = nil
            }
        default:
            heroOneShot = nil
            pendingHeroWaves = 0
        }
    }

    // MARK: Goal toggle

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

    // MARK: Start interview

    private func routePendingStartInterviewIfNeeded() {
        guard !startInterviewRequestID.isEmpty else { return }
        StepINNavigationBridge.clearStartInterviewRequest()
        startInterview()
    }

    private func startInterview() {
        guard !isStartingInterview else { return }
        if tutorialManager.isPresented {
            tutorialManager.skip()
        }
        isStartingInterview = true
        startFeedbackTrigger.toggle()
        showInterviewFlow = true
    }

    private func startHomeTutorialIfNeeded() {
        tutorialManager.onFinish = {
            appState.selectedTab = .interviews
        }

        let delay: TimeInterval = reduceMotion ? 0.15 : 0.7
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard appState.selectedTab == .home, !showInterviewFlow, !showProfile else { return }
            if shouldResumeHomeTutorialAtLastStep {
                shouldResumeHomeTutorialAtLastStep = false
                tutorialManager.startAtLastStep()
            } else {
                tutorialManager.startIfNeeded(hasCompletedTutorial: hasCompletedHomeTutorial)
            }
        }
    }

    // MARK: Recent interviews

    @ViewBuilder
    private var recentInterviewsSection: some View {
        VStack(alignment: .leading, spacing: StepINSpacing.md) {
            StepINSectionHeader(
                title: "Recent Interviews",
                actionTitle: completedInterviews.count > 2 ? "See All" : nil,
                action: completedInterviews.count > 2
                    ? { appState.selectedTab = .interviews } : nil
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
        .tutorialTarget(.recentInterviews)
    }

    // MARK: Recent goals

    @ViewBuilder
    private var recentGoalsSection: some View {
        if !recentGoals.isEmpty {
            VStack(alignment: .leading, spacing: StepINSpacing.md) {
                StepINSectionHeader(
                    title: "Recent Goals",
                    actionTitle: activeGoals.count > 3 ? "See All" : nil,
                    action: activeGoals.count > 3
                        ? { appState.selectedTab = .goals } : nil
                )
                StepINCard {
                    VStack(spacing: 0) {
                        ForEach(
                            Array(recentGoals.enumerated()),
                            id: \.element.id
                        ) { index, goal in
                            HomeGoalRow(goal: goal, onToggle: { toggle(goal) })
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

// MARK: - HomeGreetingHeader

private struct HomeGreetingHeader: View {
    let firstName: String
    let initials: String
    let profileImage: UIImage?
    let profileAction: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Button {
                profileAction()
            } label: {
                StepINProfileAvatar(image: profileImage, initials: initials)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Profile")
            .tutorialTarget(.profile)

            VStack(alignment: .leading, spacing: 3) {
                Text("Good morning,")
                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                    .foregroundStyle(StepINColor.primary)
                    .lineLimit(1)

                Text(firstName)
                    .font(.system(size: 17, weight: .semibold, design: .rounded, ))
                    .foregroundStyle(StepINColor.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }

            Spacer(minLength: 0)
        }
    }
}

// MARK: - HomeInterviewHeroCard

private struct HomeInterviewHeroCard: View {
    let appeared: Double
    let breatheY: Double
    let swayAngle: Double
    let robotState: RobotState
    let oneShot: RobertAnimationState?
    let startAction: () -> Void
    let robotTapAction: () -> Void
    let oneShotComplete: () -> Void
    let isStartingInterview: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var robotColumnWidth: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 170 : 170
    }

    private var robotSize: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 230 : 230
    }

    private var robotVisualHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 190 : 190
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            leftColumn
            robertColumn
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: dynamicTypeSize.isAccessibilitySize ? 250 : 210)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: StepINRadius.hero, style: .continuous))
        .stepINShadow(.card)
    }

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: StepINSpacing.sm) {
            Text("Ready for your next interview?")
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundColor(Color(hex: 0x393939))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            Text("Practice with an AI interviewer tailored to your role.")
                .font(.system(.subheadline, design: .rounded, weight: .regular))
                .foregroundColor(Color(hex: 0x393939).opacity(0.99))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            startButton
        }
        .padding(.leading, StepINSpacing.lg)
        .padding(.trailing, StepINSpacing.xs)
        .padding(.vertical, StepINSpacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var startButton: some View {
        Button(action: startAction) {
            Text("Start Interview")
                .font(StepINFont.button)
                .foregroundColor(StepINColor.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.84)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 50)
                .padding(.horizontal, StepINSpacing.sm)
                .background(StepINColor.primarySoft)
                .clipShape(
                    RoundedRectangle(cornerRadius: StepINRadius.medium, style: .continuous)
                )
        }
        .buttonStyle(StepINPressStyle())
        .disabled(isStartingInterview)
        .padding(.top, StepINSpacing.xs)
        .frame(maxWidth: 178)
        .accessibilityLabel("Start Interview")
        .tutorialTarget(.startInterview)
    }

    private var robertColumn: some View {
        ZStack(alignment: .bottomTrailing) {
            StepINGradient.robotGlow
                .frame(width: 230, height: 230)
                .opacity(0.1)

            Circle()
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                .frame(width: 116, height: 116)

            Circle()
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
                .frame(width: 148, height: 148)

            robertView
        }
        .frame(width: robotColumnWidth)
        .frame(minHeight: 190)
        .padding(.trailing, StepINSpacing.xs)
        .contentShape(Rectangle())
        .onTapGesture(perform: robotTapAction)
        .accessibilityElement()
        .accessibilityLabel(oneShot?.accessibilityLabel ?? robotState.toRobertState.accessibilityLabel)
        .accessibilityHint(oneShot == nil ? "Double tap to wave" : "")
    }

    private var robertView: some View {
        RobertRendererView(
            state: robotState,
            robertState: oneShot,
            presentation: .homeHero,
            size: robotSize,
            onOneShotComplete: oneShotComplete
        )
        .frame(width: robotSize, height: robotVisualHeight, alignment: .bottomTrailing)
        .opacity(appeared)
        .scaleEffect(0.92 + 0.08 * appeared)
        .offset(y: breatheY + CGFloat(12.0 * (1.0 - appeared)))
        .rotationEffect(.degrees(swayAngle), anchor: UnitPoint(x: 0.5, y: 0.12))
    }

    private var cardBackground: some View {
        RoundedRectangle(
            cornerRadius: StepINRadius.hero,
            style: .continuous
        )
        .fill(.ultraThickMaterial)
        .overlay {
            ZStack {
                Color(hex: 0x8D68F6)
                    .opacity(0.45)

                Circle()
                    .fill(Color(hex: 0xC084FC))
                    .frame(width: 240, height: 240)
                    .blur(radius: 90)
                    .offset(x: -120, y: -100)

                Circle()
                    .fill(Color(hex: 0x7DD3FC))
                    .frame(width: 220, height: 220)
                    .blur(radius: 90)
                    .offset(x: 130, y: -80)

                Circle()
                    .fill(Color(hex: 0xF39AC7))
                    .frame(width: 220, height: 220)
                    .blur(radius: 100)
                    .offset(x: 140, y: 120)

                Circle()
                    .fill(Color(hex: 0xFDBA74))
                    .frame(width: 220, height: 220)
                    .blur(radius: 110)
                    .offset(x: -120, y: 120)
            }
            .clipShape(
                RoundedRectangle(
                    cornerRadius: StepINRadius.hero,
                    style: .continuous
                )
            )
        }
        .overlay {
            LinearGradient(
                colors: [
                    Color.white.opacity(0.28),
                    Color.white.opacity(0.05),
                    .clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .clipShape(
                RoundedRectangle(
                    cornerRadius: StepINRadius.hero,
                    style: .continuous
                )
            )
        }
        .overlay {
            RoundedRectangle(
                cornerRadius: StepINRadius.hero,
                style: .continuous
            )
            .strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.45),
                        Color.white.opacity(0.12)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
        }
    }
}

// MARK: - HomeGoalRow

private struct HomeGoalRow: View {
    let goal: AssignedGoal
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: StepINSpacing.sm) {
            Button(action: onToggle) {
                Image(systemName: goal.status == .completed
                      ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundColor(
                        goal.status == .completed
                            ? StepINColor.success : StepINColor.textTertiary
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(goal.status == .completed ? "Mark goal as to do" : "Mark goal as completed")

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
    }
}

private extension AssignedGoal {
    var homeSourceLabel: String { "From \(sourceJobTitle) Interview" }
}

// MARK: - Preview

#Preview("Home") {
    HomeView()
        .environment(AppState(hasProfile: true))
        .modelContainer(PreviewData.container)
}
