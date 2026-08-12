enum InterviewsTutorial {
    static func steps(hasCompletedInterviews: Bool) -> [TutorialStep] {
        if hasCompletedInterviews {
            return [
                TutorialStep(
                    id: .interviewsSearch,
                    order: 0,
                    title: "Search interviews",
                    description: "Use this search bar to find interviews by job title, company, date, or score.",
                    bubblePosition: .below
                ),
                TutorialStep(
                    id: .interviewsList,
                    order: 1,
                    title: "Open past feedback",
                    description: "Tap an interview card to review its analysis, score, transcript, and assigned goals.",
                    bubblePosition: .above
                )
            ]
        }

        return [
            TutorialStep(
                id: .interviewsEmptyState,
                order: 0,
                title: "Your interview history",
                description: "Completed interviews will appear here after you finish a practice session from Home.",
                bubblePosition: .above
            )
        ]
    }
}

enum GoalsTutorial {
    static func steps(hasGoals: Bool) -> [TutorialStep] {
        if hasGoals {
            return [
                TutorialStep(
                    id: .goalsSearch,
                    order: 0,
                    title: "Search goals",
                    description: "Search your improvement goals by title or source interview.",
                    bubblePosition: .below
                ),
                TutorialStep(
                    id: .goalsList,
                    order: 1,
                    title: "Track your progress",
                    description: "Your goals are listed here with active items first, followed by completed goals.",
                    bubblePosition: .above
                ),
                TutorialStep(
                    id: .goalToggle,
                    order: 2,
                    title: "Complete a goal",
                    description: "Tap this circle when you finish a goal. You can tap it again to move it back to your active list.",
                    bubblePosition: .below
                )
            ]
        }

        return [
            TutorialStep(
                id: .goalsEmptyState,
                order: 0,
                title: "Your improvement goals",
                description: "After an interview, StepIN creates goals here so you know what to practice next.",
                bubblePosition: .above
            )
        ]
    }
}

enum InterviewDetailsTutorial {
    static let steps: [TutorialStep] = [
        TutorialStep(
            id: .detailsSearch,
            order: 0,
            title: "Search this interview",
            description: "Search inside the current analysis or transcript without leaving the interview details page.",
            bubblePosition: .below
        ),
        TutorialStep(
            id: .detailsSegmentedControl,
            order: 1,
            title: "Switch sections",
            description: "Use these tabs to move between feedback analysis and the saved chat history.",
            bubblePosition: .below
        ),
        TutorialStep(
            id: .analysisContent,
            order: 2,
            title: "Read your analysis",
            description: "This section shows performance scores, strengths, areas to improve, and assigned goals when available.",
            bubblePosition: .above
        ),
        TutorialStep(
            id: .chatContent,
            order: 3,
            title: "Review the conversation",
            description: "The chat history keeps the interview transcript so you can revisit what was asked and answered.",
            bubblePosition: .above
        )
    ]
}
