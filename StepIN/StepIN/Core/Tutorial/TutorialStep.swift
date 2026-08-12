import SwiftUI

enum TutorialTarget: String, Hashable, CaseIterable {
    case profile
    case startInterview
    case recentInterviews
    case recentGoals
    case interviewsSearch
    case interviewsList
    case interviewsEmptyState
    case goalsSearch
    case goalsList
    case goalsEmptyState
    case goalToggle
    case detailsSearch
    case detailsSegmentedControl
    case analysisContent
    case chatContent
}

enum TutorialBubblePosition: Hashable, Sendable {
    case above
    case below
}

struct TutorialStep: Identifiable, Hashable {
    let id: TutorialTarget
    let order: Int
    let title: String
    let description: String
    let bubblePosition: TutorialBubblePosition
}

struct TutorialTargetBoundsKey: PreferenceKey {
    static var defaultValue: [TutorialTarget: Anchor<CGRect>] = [:]

    static func reduce(value: inout [TutorialTarget: Anchor<CGRect>], nextValue: () -> [TutorialTarget: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    func tutorialTarget(_ target: TutorialTarget) -> some View {
        anchorPreference(key: TutorialTargetBoundsKey.self, value: .bounds) { anchor in
            [target: anchor]
        }
    }
}
