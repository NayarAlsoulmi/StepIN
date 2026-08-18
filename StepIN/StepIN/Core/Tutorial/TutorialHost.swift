import SwiftUI

struct TutorialHost<Content: View>: View {
    let manager: TutorialManager
    let onBack: (() -> Void)?
    let onNext: (() -> Void)?
    let advancesToAnotherPage: Bool
    let canGoBackToPreviousPage: Bool
    private let content: Content

    init(
        manager: TutorialManager,
        onBack: (() -> Void)? = nil,
        onNext: (() -> Void)? = nil,
        advancesToAnotherPage: Bool = false,
        canGoBackToPreviousPage: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.manager = manager
        self.onBack = onBack
        self.onNext = onNext
        self.advancesToAnotherPage = advancesToAnotherPage
        self.canGoBackToPreviousPage = canGoBackToPreviousPage
        self.content = content()
    }

    var body: some View {
        content
            .overlayPreferenceValue(TutorialTargetBoundsKey.self) { targets in
                GeometryReader { proxy in
                    let availableTargets = Set(targets.keys)

                    if let step = manager.currentStep,
                       let anchor = targets[step.id] {
                        TutorialOverlay(
                            step: step,
                            targetFrame: proxy[anchor],
                            stepIndex: manager.currentIndex,
                            stepCount: manager.steps.count,
                            isFirstStep: manager.isFirstStep,
                            isLastStep: manager.isLastStep,
                            advancesToAnotherPage: advancesToAnotherPage,
                            canGoBackToPreviousPage: canGoBackToPreviousPage,
                            onBack: onBack ?? manager.back,
                            onNext: onNext ?? manager.next,
                            onSkip: manager.skip
                        )
                        .zIndex(1000)
                    }

                    Color.clear
                        .task(id: availableTargets) {
                            manager.advancePastMissingTargets(availableTargets)
                        }
                }
            }
    }
}
