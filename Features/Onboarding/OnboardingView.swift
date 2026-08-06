//
//  OnboardingView.swift
//  StepIN
//
//  Three-page horizontal onboarding. Swipe or Next; final page shows
//  Get Started.
//

import SwiftUI

private struct OnboardingPage: Identifiable {
    let id = Int.random(in: 0..<Int.max)
    let robotState: RobotState
    let title: String
    let message: String
}

struct OnboardingView: View {
    /// Called when the user finishes the final page.
    let onFinished: () -> Void

    @State private var selection = 0
    // Page 0 plays wakeUp once then settles to idle.
    @State private var page0OneShot: RobertAnimationState? = .wakeUp

    private let pages: [OnboardingPage] = [
        OnboardingPage(
            robotState: .idle,
            title: "Practice interviews with AI",
            message: "Speak with a realistic AI interviewer that adapts to your answers, just like the real thing."
        ),
        OnboardingPage(
            robotState: .thinking,
            title: "Personalized for every job",
            message: "Tell us the role you're aiming for — questions are tailored to the job, the company, and your CV."
        ),
        OnboardingPage(
            robotState: .idle,
            title: "Get instant feedback",
            message: "Receive a score, personalized coaching, and improvement goals after every interview."
        )
    ]

    private var isLastPage: Bool { selection == pages.count - 1 }

    @ViewBuilder
    private func onboardingRobot(index: Int, page: OnboardingPage) -> some View {
        switch index {
        case 0:
            // wakeUp once, then settle to idle.
            RobotView(
                state: page.robotState,
                robertState: page0OneShot,
                presentation: .homeHero,
                onOneShotComplete: { page0OneShot = nil }
            )
        case 2:
            // thumbsUp once, hold on last frame.
            RobotView(state: page.robotState, robertState: .thumbsUp, presentation: .homeHero)
        default:
            RobotView(state: page.robotState, presentation: .homeHero)
        }
    }

    var body: some View {
        VStack {
            TabView(selection: $selection) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                    VStack(spacing: StepINSpacing.xl) {
                        Spacer()
                        onboardingRobot(index: index, page: page)
                        VStack(spacing: StepINSpacing.sm) {
                            Text(page.title)
                                .font(StepINFont.h1)
                                .foregroundColor(StepINColor.textPrimary)
                                .multilineTextAlignment(.center)
                            Text(page.message)
                                .font(StepINFont.bodyRegular)
                                .foregroundColor(StepINColor.textSecondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, StepINSpacing.xxl)
                        Spacer()
                        Spacer()
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            StepINPrimaryButton(title: isLastPage ? "Get Started" : "Next") {
                if isLastPage {
                    onFinished()
                } else {
                    withAnimation(StepINMotion.springStandard) { selection += 1 }
                }
            }
            .padding(.horizontal, StepINSpacing.screenH)
            .padding(.bottom, StepINSpacing.md)
        }
        .background(StepINScreenBackground())
    }
}

#Preview {
    OnboardingView(onFinished: {})
}
