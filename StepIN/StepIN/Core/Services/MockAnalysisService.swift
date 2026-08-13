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
        completedQuestionCount: Int,
        deliveryMetrics: VoiceDeliveryMetrics
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
            "Supported answers with concrete project examples.",
            "Maintained a composed delivery across answers.",
            "Connected motivation clearly to the \(role) role."
        ]
        if configuration.company != nil {
            strengths.append("Linked role interest to the company context.")
        }

        var areas = [
            "Make answers more concise while preserving key details.",
            "Structure behavioral examples with clearer action and result.",
            "Use steadier pacing during complex answers."
        ]
        if isPartial {
            areas.append("Complete full sessions to show consistent participation.")
        }

        let goalPool = [
            "Lead answers with the main point",
            "Quantify impact in project examples",
            "Explain technical trade-offs more clearly",
            "Clarify your role in team examples",
            "Use steadier pacing for complex topics"
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
            strengths: Array(strengths.prefix(4)),
            areasToImprove: Array(areas.prefix(4)),
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
