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
        viewModel: InterviewSessionViewModel? = nil,
        onFinished: @escaping (_ transcript: [TranscriptEntry], _ isPartial: Bool, _ completedCount: Int, _ metrics: VoiceDeliveryMetrics) -> Void
    ) {
        _viewModel = State(initialValue: viewModel ?? InterviewSessionViewModel(
            configuration: configuration,
            onFinished: onFinished
        ))
    }

    var body: some View {
        ZStack {
            StepINScreenBackground()

            VStack(spacing: 0) {
                topBar

                Spacer()

                // Center: robot + question + state label.
                VStack(spacing: StepINSpacing.xl) {
                    RobotView(
                        state: viewModel.robotState,
                        robertState: viewModel.robertOneShot,
                        presentation: .interview,
                        onOneShotComplete: viewModel.robertOneShotCompleted
                    )

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

            if viewModel.phase == .error {
                realtimeErrorOverlay
                    .transition(.opacity)
            }
        }
        .animation(StepINMotion.fade, value: viewModel.phase)
        .onAppear {
            #if DEBUG
            print("[InterviewStartup] T7 InterviewSessionView shown")
            #endif
            viewModel.beginInterview()
        }
        .alert(
            "End this interview?",
            isPresented: $confirmEnd
        ) {
            Button("End Interview", role: .destructive) { viewModel.endInterview() }
            Button("Continue Interview", role: .cancel) {}
        } message: {
            Text("You'll still receive feedback on the answers you've completed.")
        }
        .tint(StepINColor.textPrimary.opacity(0.72))
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            Button {
                viewModel.pause()
            } label: {
                Image(systemName: "pause.fill")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundColor(StepINColor.textSecondary)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
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
                    .background(.ultraThinMaterial, in: Capsule())
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
            StepINScreenBackground()

            VStack(spacing: StepINSpacing.xl) {
                RobotView(state: .paused, presentation: .compact)
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

    private var realtimeErrorOverlay: some View {
        ZStack {
            StepINScreenBackground()

            VStack(spacing: StepINSpacing.lg) {
                RobotView(state: .idle, presentation: .compact)
                Text("Interview Connection Issue")
                    .font(StepINFont.h2)
                    .foregroundColor(StepINColor.textPrimary)
                    .multilineTextAlignment(.center)

                if let message = viewModel.sessionErrorMessage {
                    Text(message)
                        .font(StepINFont.body3)
                        .foregroundColor(StepINColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 520)
                }

                StepINPrimaryButton(title: "Try Again") {
                    viewModel.retryAfterRealtimeError()
                }
                .padding(.horizontal, StepINSpacing.xxl)
            }
            .padding(.horizontal, StepINSpacing.screenH)
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
        onFinished: { _, _, _, _ in }
    )
}
