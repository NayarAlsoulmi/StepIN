import AppIntents

struct StepINShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartInterviewIntent(),
            phrases: [
                "Start an interview in \(.applicationName)",
                "Start my interview with \(.applicationName)",
                "Practice an interview with \(.applicationName)"
            ],
            shortTitle: "Start Interview",
            systemImageName: "mic.fill"
        )
    }
}
