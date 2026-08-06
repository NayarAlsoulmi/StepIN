//
//  MockAnalysisService.swift
//  StepIN
//
//  Offline analysis generator for demo mode and Phases 1-4. Produces
//  spec-valid structured results (five categories, 3-5 strengths and
//  areas, 1-3 goals) grounded in the transcript shape.
//

import Foundation

@MainActor
final class MockAnalysisService: InterviewAnalysisServiceProtocol {

    func analyze(
        configuration: InterviewConfiguration,
        transcript: [TranscriptEntry],
        isPartial: Bool,
        completedQuestionCount: Int
    ) async throws -> AnalysisResult {
        // Simulate model latency.
        try? await Task.sleep(for: .seconds(1.2))

        let candidateTurns = transcript.filter { $0.speaker == .candidate }
        let averageWords = candidateTurns.isEmpty ? 0 :
            candidateTurns.map { $0.text.split(separator: " ").count }.reduce(0, +) / candidateTurns.count

        // Base score influenced by answer depth and completion.
        var base = 70
        if averageWords > 25 { base += 8 }
        if averageWords > 45 { base += 4 }
        if isPartial { base -= 8 }
        base = min(max(base, 55), 92)

        func vary(_ delta: Int) -> Int { min(max(base + delta, 50), 96) }

        let answerQuality = vary(Int.random(in: -4...6))
        let clarity = vary(Int.random(in: -5...5))
        let confidence = vary(Int.random(in: -7...3))
        let communication = vary(Int.random(in: -4...5))
        let interviewSkills = vary(Int.random(in: -3...5))
        let overall = (answerQuality + clarity + confidence + communication + interviewSkills) / 5

        let role = configuration.jobTitle

        var strengths = [
            "You supported your answers with concrete examples from your projects.",
            "You stayed calm and composed throughout the interview.",
            "You showed genuine motivation for the \(role) role."
        ]
        if configuration.company != nil {
            strengths.append("You connected your interests to the company convincingly.")
        }

        var areas = [
            "Try making your answers more concise while keeping the important details.",
            "Practice structuring behavioral answers around the situation, your actions, and the result.",
            "Practice speaking with fewer pauses to keep your delivery consistent."
        ]
        if isPartial {
            areas.append("Complete a full-length interview to build stamina for longer sessions.")
        }

        let goalPool = [
            "Practice answering behavioral questions using specific examples.",
            "Practice concise introductions.",
            "Reduce filler words during interviews.",
            "Prepare stronger examples for teamwork questions.",
            "Improve confidence when discussing technical projects."
        ]
        let goals = Array(goalPool.shuffled().prefix(Int.random(in: 2...3)))

        let summary = isPartial
            ? "A promising partial interview for the \(role) role — finishing a full session will sharpen the picture further."
            : "A solid interview for the \(role) role with clear examples and room to tighten delivery."

        let result = AnalysisResult(
            overallScore: overall,
            answerQualityScore: answerQuality,
            clarityScore: clarity,
            confidenceScore: confidence,
            communicationScore: communication,
            interviewSkillsScore: interviewSkills,
            strengths: Array(strengths.prefix(5)),
            areasToImprove: Array(areas.prefix(5)),
            assignedGoals: goals,
            summary: summary
        )

        // Spec: validate structured output; retry once, then fail recoverably.
        guard result.isValid else {
            throw NSError(domain: "StepIN.Analysis", code: 1)
        }
        return result
    }
}
