//
//  RobotView.swift
//  StepIN
//
//  The official StepIN robot. RobotView accepts a RobotState (seven-state
//  session API) and maps it to a RobertAnimationState for sprite playback.
//  Pass `robertState` to override with a one-shot animation (wakeUp, wave…)
//  without changing the base `state`.
//
//  Visual behavior lives entirely in the sprite frames — this view contains
//  no layout animation, glow, or particle logic. A future RealityKit renderer
//  can replace RobertAnimationPlayer while keeping this API intact.
//

import SwiftUI

// MARK: - RobotState

/// Seven-state API used by the interview session state machine.
enum RobotState: String, CaseIterable {
    case idle
    case listening
    case speaking
    case thinking
    case analyzing
    case paused
    case success

    var toRobertState: RobertAnimationState {
        switch self {
        case .idle:      .idle
        case .listening: .listening
        case .speaking:  .speaking
        case .thinking:  .thinking
        case .analyzing: .analyzing
        case .paused:    .paused
        case .success:   .success
        }
    }
}

// MARK: - RobotPresentation

/// Context that determines the robot's default display size.
/// Sizing only — behavior always comes from RobotState / RobertAnimationState.
enum RobotPresentation {
    case homeHero    // 160 — hero card focal point
    case interview   // 140 — live session center stage
    case loading     // 130 — AI prep / analyzing screens
    case compact     // 100 — pause overlay, create profile
    case emptyState  // 120 — empty states and loading placeholders

    var size: CGFloat {
        switch self {
        case .homeHero:   160
        case .interview:  140
        case .loading:    130
        case .compact:    100
        case .emptyState: 120
        }
    }
}

// MARK: - RobotView

/// Reusable robot view. Delegates to RobertAnimationPlayer for all rendering.
struct RobotView: View {
    /// Base state — used when `robertState` is nil.
    let state: RobotState
    /// One-shot override. When non-nil, plays this state instead of `state`.
    var robertState: RobertAnimationState? = nil
    /// Display context — determines default size.
    var presentation: RobotPresentation = .compact
    /// Explicit size override in points. Ignored when nil (uses presentation.size).
    var size: CGFloat? = nil
    /// Smoothed audio level (0–1). Only affects speaking playback speed.
    var audioLevel: Double = 0
    /// Called when a one-shot animation finishes. Ignored for looping states.
    var onOneShotComplete: (() -> Void)? = nil

    private var effectiveAnimState: RobertAnimationState {
        robertState ?? state.toRobertState
    }

    private var effectiveSize: CGFloat {
        size ?? presentation.size
    }

    var body: some View {
        RobertAnimationPlayer(
            state: effectiveAnimState,
            size: effectiveSize,
            audioLevel: audioLevel,
            onComplete: onOneShotComplete
        )
    }
}

// MARK: - Preview

#Preview("All RobotStates") {
    ScrollView {
        VStack(spacing: 24) {
            ForEach(RobotState.allCases, id: \.self) { s in
                VStack(spacing: 4) {
                    RobotView(state: s, presentation: .compact)
                    Text(s.rawValue)
                        .font(StepINFont.caption)
                        .foregroundColor(StepINColor.textTertiary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
    .background(StepINColor.background)
}

#Preview("One-shot overrides") {
    ScrollView {
        VStack(spacing: 24) {
            ForEach([RobertAnimationState.wakeUp, .wave, .success, .thumbsUp, .confused], id: \.self) { s in
                VStack(spacing: 4) {
                    RobotView(state: .idle, robertState: s, presentation: .compact)
                    Text(s.rawValue)
                        .font(StepINFont.caption)
                        .foregroundColor(StepINColor.textTertiary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
    .background(StepINColor.background)
}
