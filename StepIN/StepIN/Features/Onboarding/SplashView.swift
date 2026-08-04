//
//  SplashView.swift
//  StepIN
//
//  Brief branded launch moment: robot + logo over the brand gradient.
//

import SwiftUI

struct SplashView: View {
    /// Called when the splash has finished displaying.
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var logoVisible = false

    var body: some View {
        ZStack {
            StepINGradient.hero.ignoresSafeArea()

            VStack(spacing: StepINSpacing.xl) {
                RobotView(state: .idle, presentation: .homeHero)

                VStack(spacing: StepINSpacing.xs) {
                    Text("StepIN")
                        .font(.system(size: 40, weight: .bold))
                        .foregroundColor(.white)
                    Text("Step into your next opportunity.")
                        .font(StepINFont.body1)
                        .foregroundColor(.white.opacity(0.9))
                }
                .opacity(logoVisible ? 1 : 0)
                .animation(reduceMotion ? nil : .easeIn(duration: StepINMotion.slow), value: logoVisible)
            }
        }
        .task {
            logoVisible = true
            try? await Task.sleep(for: .seconds(2.2))
            onFinished()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("StepIN. Step into your next opportunity.")
    }
}

#Preview {
    SplashView(onFinished: {})
}
