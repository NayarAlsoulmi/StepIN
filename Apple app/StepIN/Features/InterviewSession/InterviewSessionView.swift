//
//  InterviewSessionView.swift
//  StepIN
//
//  The live interview. Immersive: robot, current question, waveform, and
//  minimal controls. No transcript, no counters, no progress, no bubbles.
//

import SwiftUI

struct InterviewSessionView: View {
    @State private var viewModel: InterviewSessionViewModel
    @State private var confirmEnd = false

    init(
        configuration: InterviewConfiguration,
        onFinished: @escaping (_ transcript: [TranscriptEntry], _ isPartial: Bool, _ completedCount: Int) -> Void
    ) {
        _viewModel = State(initialValue: InterviewSessionViewModel(
            configuration: configuration,
            onFinished: onFinished
        ))
    }

    var body: some View {
        ZStack {
            StepINColor.background.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar

                Spacer()

                // Center: robot + question + state label.
                VStack(spacing: StepINSpacing.xl) {
                    RobotView(state: viewModel.robotState, size: 130)

                    Text(viewModel.currentQuestionText)
                        .font(StepINFont.h2)
                        .foregroundColor(StepINColor.textPrimary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 560)
                        .padding(.horizontal, StepINSpacing.xl)
                        .id(viewModel.currentQuestionText) // re-triggers transition
                        .transition(.opacity)
                        .animation(StepINMotion.fade, value: viewModel.currentQuestionText)

                    if !viewModel.stateLabel.isEmpty {
                        Text(viewModel.stateLabel)
                            .font(StepINFont.body4)
                            .foregroundColor(StepINColor.textTertiary)
                            .accessibilityLabel("Interview state: \(viewModel.stateLabel)")
                    }
                }

                Spacer()

                bottomArea
            }

            // Pause overlay.
            if viewModel.phase == .paused {
                pauseOverlay
                    .transition(.opacity)
            }
        }
        .animation(StepINMotion.fade, value: viewModel.phase)
        .onAppear { viewModel.start() }
        .confirmationDialog(
            "End this interview?",
            isPresented: $confirmEnd,
            titleVisibility: .visible
        ) {
            Button("End Interview", role: .destructive) { viewModel.endInterview() }
            Button("Continue Interview", role: .cancel) {}
        } message: {
            Text("You'll still receive feedback on the answers you've completed.")
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            Button {
                viewModel.pause()
            } label: {
                Image(systemName: "pause.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(StepINColor.textSecondary)
                    .frame(width: 44, height: 44)
                    .background(StepINColor.surface)
                    .clipShape(Circle())
            }
            .accessibilityLabel("Pause interview")

            Spacer()

            Button {
                confirmEnd = true
            } label: {
                Text("End")
                    .font(StepINFont.body2)
                    .foregroundColor(StepINColor.error)
                    .frame(height: 44)
                    .padding(.horizontal, StepINSpacing.md)
                    .background(StepINColor.surface)
                    .clipShape(Capsule())
            }
            .accessibilityLabel("End interview")
        }
        .padding(.horizontal, StepINSpacing.screenH)
        .padding(.top, StepINSpacing.xs)
    }

    // MARK: Bottom

    @ViewBuilder
    private var bottomArea: some View {
        VStack(spacing: StepINSpacing.lg) {
            switch viewModel.phase {
            case .interviewerSpeaking:
                WaveformView(mode: .aiSpeaking)
            case .candidateListening:
                WaveformView(mode: .candidateListening)
            default:
                // Keep layout stable without showing a waveform.
                Color.clear.frame(height: 44)
            }

            // Finish Answer: low-emphasis glass fallback, listening only.
            if viewModel.showFinishAnswer && viewModel.phase == .candidateListening {
                Button {
                    viewModel.finishAnswerPressed()
                } label: {
                    Text("Finish Answer")
                        .font(StepINFont.body3)
                        .foregroundColor(StepINColor.textPrimary)
                        .padding(.horizontal, StepINSpacing.lg)
                        .frame(height: 44)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .transition(.opacity)
                .accessibilityLabel("Finish answer")
            } else {
                Color.clear.frame(height: 44)
            }
        }
        .padding(.bottom, StepINSpacing.xl)
        .animation(StepINMotion.fade, value: viewModel.showFinishAnswer)
    }

    // MARK: Pause overlay

    private var pauseOverlay: some View {
        ZStack {
            StepINColor.background.opacity(0.97).ignoresSafeArea()

            VStack(spacing: StepINSpacing.xl) {
                RobotView(state: .paused, size: 110)
                Text("Interview Paused")
                    .font(StepINFont.h2)
                    .foregroundColor(StepINColor.textPrimary)

                VStack(spacing: StepINSpacing.sm) {
                    StepINPrimaryButton(title: "Resume Interview") {
                        viewModel.resume()
                    }
                    StepINDestructiveButton(title: "End Interview") {
                        confirmEnd = true
                    }
                }
                .padding(.horizontal, StepINSpacing.xxl)
            }
        }
    }
}

#Preview {
    InterviewSessionView(
        configuration: InterviewConfiguration(
            jobTitle: "iOS Engineer",
            company: "Apple",
            companyWebsite: nil,
            jobDescription: nil,
            interviewCV: nil,
            resolvedCVText: nil,
            questionCount: .five,
            candidateFirstName: "Nayar"
        ),
        onFinished: { _, _, _ in }
    )
}
