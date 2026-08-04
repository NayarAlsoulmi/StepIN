//
//  RobotView.swift
//  StepIN
//
//  The official StepIN robot. RobotView receives a RobotState and renders
//  it — it contains no business logic and does not decide its own state.
//
//  The artwork is the "StepINRobot" asset and is never redrawn or altered;
//  states only change motion and the glow around the character.
//

import SwiftUI

/// The mutually-exclusive robot states.
enum RobotState: String, CaseIterable {
    case idle
    case listening
    case speaking
    case thinking
    case analyzing
    case paused
    case success

    var accessibilityLabel: String {
        switch self {
        case .idle: "Robot idle"
        case .listening: "Robot listening"
        case .speaking: "Robot speaking"
        case .thinking: "Robot thinking"
        case .analyzing: "Robot analyzing"
        case .paused: "Robot paused"
        case .success: "Robot celebrating success"
        }
    }
}

struct RobotView: View {
    let state: RobotState
    var size: CGFloat = 140

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false
    @State private var successLift = false

    var body: some View {
        ZStack {
            glow

            if state == .thinking {
                thinkingParticles
            }

            Image("StepINRobot")
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .scaleEffect(bodyScale)
                .offset(y: floatOffset + (successLift ? -size * 0.06 : 0))
        }
        .frame(width: size * 1.7, height: size * 1.7)
        // Scope the repeat-forever animation to the `animate` change only.
        // Attaching `.animation(value:)` to the whole view would capture
        // in-flight layout positioning and float the robot around its
        // initial location during navigation transitions.
        .onAppear { startAnimating() }
        .onChange(of: state) { restartAnimating() }
        .animation(StepINMotion.fade, value: state)
        .accessibilityElement()
        .accessibilityLabel(Text(state.accessibilityLabel))
    }

    // MARK: Glow

    private var glow: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [glowColor.opacity(0.38), glowColor.opacity(0)],
                    center: .center,
                    startRadius: 4,
                    endRadius: size * 0.85
                )
            )
            .frame(width: size * 1.7, height: size * 1.7)
            .opacity(glowOpacity)
            .scaleEffect(reduceMotion || state == .paused ? 1 : (animate ? 1.06 : 0.94))
    }

    private var glowColor: Color {
        state == .success ? StepINColor.success : StepINColor.primary
    }

    private var glowOpacity: Double {
        switch state {
        case .idle: 0.5
        case .listening: 0.9
        case .speaking: 0.75
        case .thinking: 0.6
        case .analyzing: 1.0
        case .paused: 0.25
        case .success: 0.9
        }
    }

    // MARK: Thinking particles

    /// Three soft dots drifting upward behind the robot's head.
    private var thinkingParticles: some View {
        ZStack {
            particle(x: -0.32, delayPhase: 0.0)
            particle(x: 0.0, delayPhase: 0.5)
            particle(x: 0.30, delayPhase: 1.0)
        }
        .offset(y: -size * 0.5)
    }

    private func particle(x: CGFloat, delayPhase: Double) -> some View {
        Circle()
            .fill(StepINColor.primaryLight)
            .frame(width: size * 0.05, height: size * 0.05)
            .offset(x: size * x, y: animate ? -size * 0.12 : size * 0.04)
            .opacity(reduceMotion ? 0.4 : (animate ? 0 : 0.55))
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 1.6)
                    .repeatForever(autoreverses: true)
                    .delay(delayPhase * 0.4),
                value: animate
            )
    }

    // MARK: State-driven motion

    private var bodyScale: CGFloat {
        guard !reduceMotion else { return 1 }
        switch state {
        case .idle:
            // Subtle breathing.
            return animate ? 1.015 : 0.995
        case .listening:
            // Slight forward focus with a soft pulse.
            return animate ? 1.035 : 1.015
        case .speaking:
            // Slight body response to the voice.
            return animate ? 1.02 : 1.0
        default:
            return 1
        }
    }

    private var floatOffset: CGFloat {
        guard !reduceMotion else { return 0 }
        switch state {
        case .idle: return animate ? -4 : 4
        case .listening: return animate ? -2 : 2
        case .speaking: return animate ? -1.5 : 1.5
        default: return 0
        }
    }

    private var bodyAnimation: Animation? {
        guard !reduceMotion else { return nil }
        switch state {
        case .idle:
            return .easeInOut(duration: 2.4).repeatForever(autoreverses: true)
        case .listening:
            return .easeInOut(duration: 1.4).repeatForever(autoreverses: true)
        case .speaking:
            return .easeInOut(duration: 0.5).repeatForever(autoreverses: true)
        case .thinking:
            return .easeInOut(duration: 1.6).repeatForever(autoreverses: true)
        case .analyzing:
            return .easeInOut(duration: 1.8).repeatForever(autoreverses: true)
        case .paused, .success:
            return nil
        }
    }

    private func startAnimating() {
        guard !reduceMotion, let bodyAnimation else { return }
        withAnimation(bodyAnimation) { animate = true }
    }

    /// Re-run the loop with the new state's timing curve.
    private func restartAnimating() {
        if state == .success {
            playSuccess()
            return
        }
        guard let bodyAnimation else {
            // Paused (or Reduce Motion): settle gently instead of freezing mid-flight.
            withAnimation(.easeOut(duration: StepINMotion.standard)) { animate = false }
            return
        }
        withAnimation(bodyAnimation) { animate.toggle() }
    }

    /// One-shot: a small upward movement with a brief success glow.
    private func playSuccess() {
        withAnimation(.easeOut(duration: StepINMotion.standard)) { animate = false }
        guard !reduceMotion else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.65)) { successLift = true }
        Task {
            try? await Task.sleep(for: .seconds(0.7))
            withAnimation(.easeInOut(duration: StepINMotion.standard)) { successLift = false }
        }
    }
}

#Preview {
    ScrollView {
        VStack(spacing: 24) {
            ForEach(RobotState.allCases, id: \.self) { state in
                VStack(spacing: 4) {
                    RobotView(state: state, size: 90)
                    Text(state.rawValue)
                        .font(StepINFont.caption)
                        .foregroundColor(StepINColor.textTertiary)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
    .background(StepINColor.background)
}
