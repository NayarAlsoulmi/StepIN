//
//  MockInterviewEngine.swift
//  StepIN
//
//  Offline interview engine for demo mode, previews, and Phases 1-4.
//  Generates context-aware questions from the interview configuration —
//  no fixed script order, follow-ups count toward the total, and the
//  closing question is always extra. Also supplies simulated candidate
//  answers so the full flow can be demonstrated without a microphone.
//

import Foundation

@MainActor
final class MockInterviewEngine: InterviewEngineProtocol {

    let finalPhrase = "Thank you. That concludes our interview."

    private(set) var askedQuestionCount = 0

    private var configuration: InterviewConfiguration?
    private var questionPool: [String] = []
    private var followUpPool: [String] = []
    private var closingAsked = false
    private var lastQuestionWasFollowUp = false
    private var answersReceived = 0

    // MARK: Engine

    func start(configuration: InterviewConfiguration) async throws -> InterviewQuestion {
        self.configuration = configuration
        buildPools(for: configuration)

        // The AI chooses its own realistic opening — never fixed.
        let openings = [
            "Thanks for joining me today. Could you tell me a little about yourself?",
            "It's great to meet you. Walk me through your background, please.",
            "Let's get started. Could you briefly introduce yourself?",
            "To begin, tell me about yourself and what led you to apply for this role."
        ]
        askedQuestionCount = 1
        return InterviewQuestion(
            text: openings.randomElement()!,
            isClosing: false,
            countsTowardTotal: true
        )
    }

    func submitAnswer(_ answer: String) async throws -> InterviewQuestion? {
        guard let configuration else { return nil }
        answersReceived += 1

        // Closing question answered → interview over.
        if closingAsked { return nil }

        // Reached the selected count → ask the extra closing question.
        if askedQuestionCount >= configuration.questionCount.rawValue {
            closingAsked = true
            return InterviewQuestion(
                text: "Before we wrap up, is there anything else you'd like to add?",
                isClosing: true,
                countsTowardTotal: false
            )
        }

        // Occasionally follow up naturally (never twice in a row).
        let shouldFollowUp = !lastQuestionWasFollowUp
            && !followUpPool.isEmpty
            && answersReceived % 3 == 1
            && askedQuestionCount < configuration.questionCount.rawValue

        let text: String
        if shouldFollowUp {
            text = followUpPool.removeFirst()
            lastQuestionWasFollowUp = true
        } else {
            text = questionPool.isEmpty
                ? "What would you say is your greatest professional strength?"
                : questionPool.removeFirst()
            lastQuestionWasFollowUp = false
        }

        askedQuestionCount += 1
        return InterviewQuestion(text: text, isClosing: false, countsTowardTotal: true)
    }

    // MARK: Simulated candidate answers (demo only)

    /// A plausible sample answer for demo flows without a microphone.
    func simulatedAnswer() -> String {
        let samples = [
            "Sure. I recently graduated in computer science, and during university I worked on several team projects, including a mobile app for student events. I really enjoy building products that people actually use.",
            "In my final-year project, I led a small team of three. I was responsible for the design and coordinating our weekly milestones, and we delivered on time.",
            "I'd say my strength is learning quickly. When our project needed a technology none of us knew, I spent a weekend building a small prototype to get us started.",
            "One challenge was when two team members disagreed on the architecture. I organized a short session where we compared both approaches against our deadline, and we reached a decision together.",
            "I'm drawn to this role because it matches what I enjoyed most in my studies, and I want to keep growing in a team that values quality.",
            "That's a good question. I once had to present our project to a non-technical audience, so I focused on the outcomes instead of the implementation details, and the feedback was very positive.",
            "I think that covers it — thank you for the opportunity to share."
        ]
        return samples[min(answersReceived, samples.count - 1)]
    }

    // MARK: Question generation

    private func buildPools(for config: InterviewConfiguration) {
        var pool: [String] = []
        let role = config.jobTitle

        // Role-driven questions (primary source).
        pool.append("What interests you most about working as a \(role)?")
        pool.append("Which skills do you believe are most important for a \(role), and why?")
        pool.append("Where do you see yourself growing within the \(role) field over the next few years?")

        // Company-driven questions.
        if let company = config.company {
            pool.append("What made you interested in \(company) specifically?")
            pool.append("How do you think you could contribute to a team at \(company)?")
        }

        // Job-description-driven questions.
        if config.jobDescription != nil {
            pool.append("Looking at the responsibilities of this role, which part do you feel most prepared for?")
            pool.append("The role involves collaborating across teams. Can you share an experience where you did that?")
        }

        // CV-driven questions.
        if config.resolvedCVText != nil {
            pool.append("I've looked over your CV. Could you walk me through the experience you're most proud of?")
            pool.append("From your background, which project taught you the most, and why?")
        }

        // Behavioral / situational.
        pool.append("Tell me about a time you faced a challenge in a team. How did you handle it?")
        pool.append("Describe a situation where you had to learn something new under time pressure.")
        pool.append("Can you share an example of receiving difficult feedback and what you did with it?")
        pool.append("Tell me about a time you had to balance multiple priorities.")
        pool.append("Describe a moment when something didn't go as planned. What did you do?")

        questionPool = pool.shuffled()

        followUpPool = [
            "Could you tell me more about your role in that?",
            "How did you approach that process?",
            "What was the outcome, and what would you do differently?",
            "What did you learn from that experience?"
        ].shuffled()
    }
}
