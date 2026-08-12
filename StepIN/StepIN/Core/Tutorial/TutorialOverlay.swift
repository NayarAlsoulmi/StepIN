import SwiftUI

struct TutorialOverlay: View {
    let step: TutorialStep
    let targetFrame: CGRect
    let stepIndex: Int
    let stepCount: Int
    let isFirstStep: Bool
    let isLastStep: Bool
    let advancesToAnotherPage: Bool
    let canGoBackToPreviousPage: Bool
    let onBack: () -> Void
    let onNext: () -> Void
    let onSkip: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let highlightPadding: CGFloat = 8
    private let bubbleMaxWidth: CGFloat = 320

    private var canGoBack: Bool {
        !isFirstStep || canGoBackToPreviousPage
    }

    var body: some View {
        GeometryReader { proxy in
            let highlightFrame = targetFrame.insetBy(dx: -highlightPadding, dy: -highlightPadding)
            let bubbleFrame = bubbleFrame(in: proxy.size, highlightFrame: highlightFrame)

            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.54)
                    .ignoresSafeArea()

                RoundedRectangle(cornerRadius: StepINRadius.large, style: .continuous)
                    .strokeBorder(StepINColor.primary, lineWidth: 3)
                    .background(
                        RoundedRectangle(cornerRadius: StepINRadius.large, style: .continuous)
                            .fill(Color.white.opacity(0.12))
                    )
                    .frame(width: highlightFrame.width, height: highlightFrame.height)
                    .position(x: highlightFrame.midX, y: highlightFrame.midY)
                    .shadow(color: StepINColor.primary.opacity(0.35), radius: 18)

                bubble
                    .frame(maxWidth: bubbleMaxWidth)
                    .position(x: bubbleFrame.midX, y: bubbleFrame.midY)
            }
            .contentShape(Rectangle())
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
            .animation(reduceMotion ? nil : StepINMotion.springStandard, value: step.id)
            .accessibilityElement(children: .contain)
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: StepINSpacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(stepIndex + 1) of \(stepCount)")
                    .font(StepINFont.caption)
                    .foregroundColor(StepINColor.textTertiary)
                Spacer()
                Button("Skip", action: onSkip)
                    .font(StepINFont.body3)
                    .foregroundColor(StepINColor.textSecondary)
            }

            VStack(alignment: .leading, spacing: StepINSpacing.xs) {
                Text(step.title)
                    .font(StepINFont.h3)
                    .foregroundColor(StepINColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(step.description)
                    .font(StepINFont.bodyRegular)
                    .foregroundColor(StepINColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: StepINSpacing.sm) {
                Button("Back", action: onBack)
                    .font(StepINFont.button)
                    .foregroundColor(canGoBack ? StepINColor.primary : StepINColor.textTertiary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(StepINColor.primarySoft.opacity(canGoBack ? 1 : 0.35))
                    .clipShape(RoundedRectangle(cornerRadius: StepINRadius.medium, style: .continuous))
                    .disabled(!canGoBack)

                Button(isLastStep && !advancesToAnotherPage ? "Done" : "Next", action: onNext)
                    .font(StepINFont.button)
                    .foregroundColor(StepINColor.onPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(StepINColor.primary)
                    .clipShape(RoundedRectangle(cornerRadius: StepINRadius.medium, style: .continuous))
            }
        }
        .padding(StepINSpacing.md)
        .background(StepINColor.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: StepINRadius.large, style: .continuous))
        .stepINShadow(.card)
        .padding(.horizontal, StepINSpacing.screenH)
    }

    private func bubbleFrame(in size: CGSize, highlightFrame: CGRect) -> CGRect {
        let width = min(bubbleMaxWidth, size.width - StepINSpacing.screenH * 2)
        let estimatedHeight: CGFloat = 214
        let spacing: CGFloat = StepINSpacing.md
        let minY = StepINSpacing.md
        let maxY = max(minY, size.height - estimatedHeight - StepINSpacing.md)

        let preferredY: CGFloat
        switch step.bubblePosition {
        case .above:
            preferredY = highlightFrame.minY - spacing - estimatedHeight / 2
        case .below:
            preferredY = highlightFrame.maxY + spacing + estimatedHeight / 2
        }

        let centerX = min(max(highlightFrame.midX, width / 2 + StepINSpacing.screenH), size.width - width / 2 - StepINSpacing.screenH)
        let centerY = min(max(preferredY, minY + estimatedHeight / 2), maxY + estimatedHeight / 2)

        return CGRect(
            x: centerX - width / 2,
            y: centerY - estimatedHeight / 2,
            width: width,
            height: estimatedHeight
        )
    }
}
