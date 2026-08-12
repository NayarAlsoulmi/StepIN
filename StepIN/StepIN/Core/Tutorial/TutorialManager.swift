import Foundation
import Observation

@Observable
final class TutorialManager {
    static let homeTutorialCompletedKey = "stepin.homeTutorialCompleted"
    static let homeTutorialResumeAtLastStepKey = "stepin.homeTutorialResumeAtLastStep"
    static let interviewsTutorialCompletedKey = "stepin.interviewsTutorialCompleted"
    static let interviewsTutorialResumeAtLastStepKey = "stepin.interviewsTutorialResumeAtLastStep"
    static let goalsTutorialCompletedKey = "stepin.goalsTutorialCompleted"
    static let interviewDetailsTutorialCompletedKey = "stepin.interviewDetailsTutorialCompleted"

    private(set) var isPresented = false
    private(set) var currentIndex = 0
    private(set) var steps: [TutorialStep]
    let completionKey: String
    var onFinish: (() -> Void)?

    var currentStep: TutorialStep? {
        guard isPresented, steps.indices.contains(currentIndex) else { return nil }
        return steps[currentIndex]
    }

    var isFirstStep: Bool { currentIndex == 0 }
    var isLastStep: Bool { currentIndex == steps.count - 1 }

    init(steps: [TutorialStep], completionKey: String = TutorialManager.homeTutorialCompletedKey) {
        self.steps = steps.sorted { $0.order < $1.order }
        self.completionKey = completionKey
    }

    func updateSteps(_ steps: [TutorialStep]) {
        self.steps = steps.sorted { $0.order < $1.order }
        if currentIndex >= self.steps.count {
            currentIndex = 0
        }
    }

    func startIfNeeded(hasCompletedTutorial: Bool) {
        guard !hasCompletedTutorial, !isPresented, !steps.isEmpty else { return }
        currentIndex = 0
        isPresented = true
    }

    func replay() {
        guard !steps.isEmpty else { return }
        currentIndex = 0
        isPresented = true
    }

    func startAtLastStep() {
        guard !steps.isEmpty else { return }
        currentIndex = steps.count - 1
        isPresented = true
    }

    func dismissWithoutCompleting() {
        isPresented = false
        currentIndex = 0
    }

    func advancePastMissingTargets(_ availableTargets: Set<TutorialTarget>) {
        guard isPresented, !availableTargets.isEmpty else { return }

        while let step = currentStep, !availableTargets.contains(step.id) {
            if isLastStep {
                finish()
            } else {
                currentIndex += 1
            }
        }
    }

    func next() {
        guard !isLastStep else {
            finish()
            return
        }
        currentIndex += 1
    }

    func moveToStep(target: TutorialTarget) {
        guard let index = steps.firstIndex(where: { $0.id == target }) else { return }
        currentIndex = index
        isPresented = true
    }

    func back() {
        guard !isFirstStep else { return }
        currentIndex -= 1
    }

    func skip() {
        finish(shouldAdvance: false)
    }

    func finish(shouldAdvance: Bool = true) {
        isPresented = false
        currentIndex = 0
        UserDefaults.standard.set(true, forKey: completionKey)

        if shouldAdvance {
            onFinish?()
        }
    }
}
