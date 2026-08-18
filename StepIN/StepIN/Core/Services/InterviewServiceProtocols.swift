//
//  InterviewServiceProtocols.swift
//  StepIN
//
//  Provider-agnostic service interfaces. ViewModels depend on these,
//  never on a concrete AI vendor. Mock implementations power previews,
//  demo mode, and Phases 1-4; realtime implementations arrive in Phase 6.
//

import Foundation

// MARK: - Interview engine

/// One question produced by the interviewer.
struct InterviewQuestion: Sendable, Equatable {
    let text: String
    /// The extra closing question ("...anything else you'd like to add?").
    let isClosing: Bool
    /// Whether it counts toward the selected question total.
    let countsTowardTotal: Bool
}

/// On-device Core ML voice classification for one candidate speaking turn.
struct VoicePerformanceResult: Sendable {
    let label: String       // e.g. "Calm", "Neutral"
    let confidence: Double  // 0.0–1.0
}

/// A single transcript entry produced during a session.
struct TranscriptEntry: Sendable {
    let speaker: MessageSpeaker
    let text: String
    /// Voice classification captured for this turn (candidate entries only).
    let voiceResult: VoicePerformanceResult?

    init(speaker: MessageSpeaker, text: String, voiceResult: VoicePerformanceResult? = nil) {
        self.speaker = speaker
        self.text = text
        self.voiceResult = voiceResult
    }
}

@MainActor
protocol InterviewEngineProtocol: AnyObject {
    /// Prepares the session and returns the opening question.
    func start(configuration: InterviewConfiguration) async throws -> InterviewQuestion

    /// Submits the candidate's answer; returns the next question, or nil
    /// when the interview is over (closing question answered).
    func submitAnswer(_ answer: String) async throws -> InterviewQuestion?

    /// Number of counted questions asked so far.
    var askedQuestionCount: Int { get }

    /// The exact phrase that ends every interview.
    var finalPhrase: String { get }
}

// MARK: - Analysis

/// Structured result of post-interview analysis. All scores 0-100.
struct AnalysisResult: Sendable {
    let overallScore: Int
    let answerQualityScore: Int
    let clarityScore: Int
    let confidenceScore: Int
    let communicationScore: Int
    let interviewSkillsScore: Int
    let strengths: [String]
    let areasToImprove: [String]
    let assignedGoals: [String]
    let summary: String

    /// Spec validation: scores in range, evidence-backed feedback may omit unsupported items.
    var isValid: Bool {
        let scores = [overallScore, answerQualityScore, clarityScore,
                      confidenceScore, communicationScore, interviewSkillsScore]
        return scores.allSatisfy { (0...100).contains($0) }
            && strengths.count <= 4
            && areasToImprove.count <= 4
            && assignedGoals.count <= 3
    }
}

@MainActor
protocol InterviewAnalysisServiceProtocol: AnyObject {
    func analyze(
        configuration: InterviewConfiguration,
        transcript: [TranscriptEntry],
        isPartial: Bool,
        completedQuestionCount: Int,
        deliveryMetrics: VoiceDeliveryMetrics
    ) async throws -> AnalysisResult
}
