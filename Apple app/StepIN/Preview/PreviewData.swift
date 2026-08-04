//
//  PreviewData.swift
//  StepIN
//
//  In-memory fixtures for SwiftUI previews and development. Never used in
//  production paths.
//

import Foundation
import SwiftData

@MainActor
enum PreviewData {
    /// An in-memory model container seeded with representative fixtures.
    static let container: ModelContainer = {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(
            for: Schema(StepINSchema.models),
            configurations: config
        )
        seed(into: container.mainContext)
        return container
    }()

    /// An empty in-memory container (no interviews / goals) for empty-state previews.
    static let emptyContainer: ModelContainer = {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(
            for: Schema(StepINSchema.models),
            configurations: config
        )
        container.mainContext.insert(sampleProfile())
        return container
    }()

    static func sampleProfile() -> UserProfile {
        UserProfile(firstName: "Nayar", lastName: "Alsoulmi", email: "nayar@example.com")
    }

    static func seed(into context: ModelContext) {
        context.insert(sampleProfile())

        // One completed interview with analysis.
        let interview = InterviewRecord(
            title: "iOS Engineer at Apple",
            jobTitle: "iOS Engineer",
            company: "Apple",
            selectedQuestionCount: 10,
            completedQuestionCount: 10,
            startedAt: Calendar.current.date(byAdding: .day, value: -2, to: .now)!,
            endedAt: Calendar.current.date(byAdding: .day, value: -2, to: .now)!,
            duration: 22 * 60,
            overallScore: 84,
            isPartial: false,
            status: .completed
        )

        let analysis = InterviewAnalysis(
            overallScore: 84,
            answerQualityScore: 82,
            clarityScore: 88,
            confidenceScore: 79,
            communicationScore: 85,
            interviewSkillsScore: 86,
            strengths: [
                "You explained your university project using clear real-world examples.",
                "You remained calm while answering technical questions.",
                "You demonstrated strong understanding of UX research principles."
            ],
            areasToImprove: [
                "Try making your answers more concise while keeping the important details.",
                "Practice speaking with fewer pauses to improve confidence during interviews.",
                "Prepare stronger examples for teamwork questions."
            ],
            summary: "A confident, well-structured interview with room to tighten pacing."
        )
        interview.analysis = analysis

        let turns: [(MessageSpeaker, String)] = [
            (.interviewer, "Thanks for joining today. Could you tell me a little about yourself?"),
            (.candidate, "Sure. I'm a recent computer science graduate focused on iOS development."),
            (.interviewer, "Great. Could you walk me through a project you're proud of?"),
            (.candidate, "I built an e-commerce app where I designed the UI and handled networking.")
        ]
        for (index, turn) in turns.enumerated() {
            let message = InterviewMessage(speaker: turn.0, text: turn.1, sequenceNumber: index)
            message.interview = interview
            context.insert(message)
        }

        context.insert(interview)

        // Goals (mix of to-do and completed).
        let goals = [
            AssignedGoal(interviewID: interview.id, title: "Practice concise introductions.", sourceInterviewTitle: interview.title, sourceJobTitle: interview.jobTitle, sourceCompany: interview.company),
            AssignedGoal(interviewID: interview.id, title: "Reduce filler words during interviews.", sourceInterviewTitle: interview.title, sourceJobTitle: interview.jobTitle, sourceCompany: interview.company),
            AssignedGoal(interviewID: interview.id, title: "Prepare stronger teamwork examples.", sourceInterviewTitle: interview.title, sourceJobTitle: interview.jobTitle, sourceCompany: interview.company, completedAt: .now, status: .completed)
        ]
        goals.forEach { context.insert($0) }
    }
}
