//
//  AnalyzingView.swift
//  StepIN
//
//  Post-interview transition: robot in Analyzing state with progressive
//  messages while the analysis is generated. Auto-advances to Results.
//

import SwiftUI

struct AnalyzingView: View {
    @State private var visibleCount = 0

    private let steps = [
        "Reviewing your answers",
        "Evaluating communication",
        "Analyzing speaking patterns",
        "Creating personalized feedback",
        "Generating improvement goals"
    ]

    var body: some View {
        ZStack {
            StepINScreenBackground()

            VStack(spacing: StepINSpacing.xxl) {
                Spacer()
                RobotView(state: .analyzing, presentation: .loading)

                VStack(spacing: StepINSpacing.xs) {
                    Text("Thank you for your time today.")
                        .font(StepINFont.h3)
                        .foregroundColor(StepINColor.textPrimary)
                    Text("Analyzing your interview...")
                        .font(StepINFont.bodyRegular)
                        .foregroundColor(StepINColor.textSecondary)
                }

                VStack(alignment: .leading, spacing: StepINSpacing.md) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        if index < visibleCount {
                            HStack(spacing: StepINSpacing.sm) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(StepINColor.success)
                                Text(step)
                                    .font(StepINFont.body2)
                                    .foregroundColor(StepINColor.textPrimary)
                            }
                            .transition(.opacity)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, StepINSpacing.xxl)
                .animation(StepINMotion.fade, value: visibleCount)

                Spacer()
                Spacer()
            }
        }
        .task {
            let step = 4.5 / Double(steps.count)
            for _ in steps {
                try? await Task.sleep(for: .seconds(step))
                visibleCount += 1
            }
        }
        .accessibilityLabel("Analyzing your interview")
    }
}

#Preview {
    AnalyzingView()
}
