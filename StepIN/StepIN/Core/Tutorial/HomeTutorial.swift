enum HomeTutorial {
    static let steps: [TutorialStep] = [
        TutorialStep(
            id: .profile,
            order: 0,
            title: "Your profile",
            description: "Update your profile details here so StepIN can personalize your practice experience.",
            bubblePosition: .below
        ),
        TutorialStep(
            id: .startInterview,
            order: 1,
            title: "Start practicing",
            description: "Start your first practice interview here. StepIN will tailor questions to your role and CV.",
            bubblePosition: .below
        ),
        TutorialStep(
            id: .recentInterviews,
            order: 2,
            title: "Review feedback",
            description: "Your completed interviews appear here so you can revisit scores, analysis, and chat history.",
            bubblePosition: .above
        )
    ]
}
