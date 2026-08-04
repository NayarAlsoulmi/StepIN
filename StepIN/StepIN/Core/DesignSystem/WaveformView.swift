//
//  WaveformView.swift
//  StepIN
//
//  Animated audio waveform. AI speaking uses smooth controlled motion;
//  candidate listening is livelier. Purely visual — real audio levels can
//  drive `level` in the realtime phase.
//

import SwiftUI

struct WaveformView: View {
    enum Mode {
        case aiSpeaking
        case candidateListening
    }

    let mode: Mode
    /// 0...1 input level. Mock flows leave the default.
    var level: Double = 0.7

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animating = false

    private let barCount = 24

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(barColor)
                    .frame(width: 3.5, height: barHeight(index))
            }
        }
        .frame(height: 44)
        // Scoped withAnimation instead of `.animation(value:)` so the
        // repeat-forever loop never captures container layout changes.
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(
                .easeInOut(duration: mode == .aiSpeaking ? 0.55 : 0.35)
                    .repeatForever(autoreverses: true)
            ) {
                animating = true
            }
        }
        .accessibilityHidden(true)
    }

    private var barColor: Color {
        mode == .aiSpeaking ? StepINColor.primary : StepINColor.primaryLight
    }

    private func barHeight(_ index: Int) -> CGFloat {
        // A gentle sine envelope so center bars are taller.
        let position = Double(index) / Double(barCount - 1)
        let envelope = sin(position * .pi)
        let base: Double = 6
        let peak = 36.0 * envelope * level
        // Alternate phase between neighboring bars while animating.
        let phase = animating != (index % 2 == 0) ? 1.0 : 0.45
        return CGFloat(base + peak * phase)
    }
}

#Preview {
    VStack(spacing: 40) {
        WaveformView(mode: .aiSpeaking)
        WaveformView(mode: .candidateListening)
    }
    .padding()
    .background(StepINColor.background)
}
