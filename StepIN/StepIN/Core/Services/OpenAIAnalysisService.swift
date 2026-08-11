//
//  OpenAIAnalysisService.swift
//  StepIN
//
//  Production analysis service. Keeps the existing Results UI contract while
//  enforcing evidence-backed feedback rules from the authoritative prompt.
//

import Foundation

@MainActor
final class OpenAIAnalysisService: InterviewAnalysisServiceProtocol {
    private let apiKey: String
    private let model = "gpt-5-mini"

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func analyze(
        configuration: InterviewConfiguration,
        transcript: [TranscriptEntry],
        isPartial: Bool,
        completedQuestionCount: Int
    ) async throws -> AnalysisResult {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "model": model,
            "input": [
                [
                    "role": "system",
                    "content": analysisInstructions(for: configuration)
                ],
                [
                    "role": "user",
                    "content": transcriptText(transcript, isPartial: isPartial, completedQuestionCount: completedQuestionCount)
                ]
            ],
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": "stepin_interview_analysis",
                    "schema": analysisSchema,
                    "strict": true
                ]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        #if DEBUG
        let requestStartedAt = Date.now
        print("[StepIN.AnalysisTiming] T1 OpenAI request sent")
        #endif

        let (data, response) = try await URLSession.shared.data(for: request)

        #if DEBUG
        print("[StepIN.AnalysisTiming] T2 OpenAI response received: \(Date.now.timeIntervalSince(requestStartedAt))s")
        #endif

        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw AnalysisError.requestFailed
        }

        let text = try extractOutputText(from: data)
        let result = try decodeAnalysisResult(from: text)
        guard result.isValid else { throw AnalysisError.invalidResult }

        #if DEBUG
        print("[StepIN.AnalysisTiming] T3 structured result parsed: \(Date.now.timeIntervalSince(requestStartedAt))s")
        #endif

        return result
    }

    private func analysisInstructions(for configuration: InterviewConfiguration) -> String {
        """
        You are StepIN's interview evaluator. Return only the requested JSON object that matches the schema.

        Evaluation context:
        - Job Title: \(configuration.jobTitle)
        - Company: \(configuration.company?.analysisNilIfBlank ?? "Not provided")
        - Job Description: \(configuration.jobDescription?.analysisNilIfBlank ?? "Not provided")
        - CV: \(configuration.resolvedCVText?.analysisNilIfBlank ?? "Not provided")
        - Selected counted question budget: \(configuration.questionCount.rawValue)

        Evidence rules:
        - Use only evidence from the provided setup data and transcript.
        - Never invent candidate facts, experience, projects, skills, certificates, achievements, responsibilities, metrics, motivations, or gaps.
        - Exclude the greeting, brief acknowledgements, clarification prompts, and final closing question from direct scoring.
        - If the interview is Partial, evaluate only completed evidence. Do not score future unanswered questions as zero.
        - If the candidate skipped or refused a counted question, score that answered item as zero evidence for that question.
        - Do not penalize untested capabilities. Treat unobserved dimensions as insufficient evidence, not weaknesses.
        - Prefer recurring patterns over isolated mistakes.
        - The CV provides context for interview questions only. Skills, projects, experience, and certifications listed on the CV do not constitute performance evidence and must not generate scores, strengths, weaknesses, or goals. Only the candidate's actual spoken answers in the transcript are performance evidence.

        Scoring rules:
        - overallScore must be 0-100 and reflect general performance across dimensions actually observed.
        - Provide scores for the existing five UI fields: answerQualityScore, clarityScore, confidenceScore, communicationScore, and interviewSkillsScore.
        - Adapt the meaning and weighting of those scores to the Job Title, actual interview coverage, CV, job description, and observed answers.
        - Do not make every dimension equal weight by default. Redistribute emphasis across observed dimensions.
        - For confidence, combine answer content with reliable delivery evidence from the transcript when available, but do not infer internal emotional state.

        Feedback rules:
        - Strengths: target 4, return fewer when evidence is insufficient. Each must express one clear evidence-backed strength in specific, natural language.
        - Strengths should usually be 6-12 words. Do not compress to a short label. Two lines are acceptable when they add clarity; padding is not.
        - Each strength must be grounded in the candidate's actual interview answers, not CV content alone.
        - Avoid opening filler such as "Demonstrates", "Shows the ability to", "Has the capability to", or "Provides evidence of". Write the strength directly.
        - Target this level of specificity: "Demonstrated strong practical experience with AI projects", "Explained technical decisions clearly with relevant examples", "Showed solid practical experience developing with SwiftUI". Do not copy these — generate from the actual interview.
        - Areas to Improve: up to 4. Each must identify one evidence-backed improvement area clearly and directly.
        - Areas should usually be 6-12 words. Do not compress to a vague label. Two lines are acceptable when they add specificity; padding is not.
        - Avoid opener filler such as "Would benefit from", "Could improve by", "In future interviews", "Consider working on", or "Try to".
        - Target this level of specificity: "Provide more detail when explaining technical implementation", "Structure longer answers with a clearer sequence", "Include measurable outcomes when discussing project impact". Do not copy these — generate from the actual interview.
        - Goals: up to 3. Each goal must derive directly from a supported Area to Improve and be specific, achievable, and connected to this interview.
        - Each goal string must be one short, meaningful action statement that answers only: "What should this candidate improve?"
        - Prefer 5-9 words. Never exceed 10 words.
        - Write goals for a one-line card target on a normal iPhone width.
        - Never include examples in parentheses, explanations, subtitles, paragraphs, checklists, implementation instructions, or mini coaching plans.
        - Never combine two improvement goals with "and" unless they are inseparable.
        - Do not make goals so short that they become generic labels like "Improve teamwork", "Improve ML", or "Be concise".
        - Good goal examples: "Quantify your impact in project examples", "Explain your technical decisions more clearly", "Keep interview responses calm and professional", "Clarify your individual contribution to team projects", "Support research answers with concrete evidence", "Make technical explanations more concise".
        - Do not start goals with "For future interviews", "You should", "Try to", "Adopt and practice", or "Prepare a concise".
        - Do not add unsupported strengths, weaknesses, or goals to fill UI space.
        - STAR is not the default recommendation. Use STAR or situation-task-action-result language only when the evidence specifically shows a behavioral or situational answer needs clearer story structure.
        - Do not recommend STAR for technical knowledge, ML knowledge, iOS knowledge, design reasoning, architecture, problem solving, confidence, concise answers, CV clarity, tool knowledge, decision-making, company motivation, or domain knowledge unless the actual weakness is behavioral story structure.
        - For technical or role-specific weaknesses, make the goal directly address the real gap, such as explaining decisions, trade-offs, outcomes, implementation reasoning, research methods, or domain concepts more clearly.
        - Return summary as an empty string.
        - Never expose internal notes, evidence IDs, coverage maps, hidden weights, raw voice statistics, chain-of-thought, or internal reasoning.
        """
    }

    private func transcriptText(_ transcript: [TranscriptEntry], isPartial: Bool, completedQuestionCount: Int) -> String {
        let lines = transcript.map { entry in
            let speaker = entry.speaker == .candidate ? "Candidate" : "AI Interviewer"
            return "\(speaker): \(entry.text)"
        }.joined(separator: "\n")

        return """
        Interview status: \(isPartial ? "Partial" : "Completed")
        Completed counted questions: \(completedQuestionCount)

        Transcript:
        \(lines)
        """
    }

    private func extractOutputText(from data: Data) throws -> String {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AnalysisError.invalidResult
        }

        if let outputText = object["output_text"] as? String {
            return outputText
        }

        if let output = object["output"] as? [[String: Any]] {
            for item in output {
                guard let content = item["content"] as? [[String: Any]] else { continue }
                for part in content {
                    if let text = part["text"] as? String {
                        return text
                    }
                }
            }
        }

        throw AnalysisError.invalidResult
    }

    private func decodeAnalysisResult(from text: String) throws -> AnalysisResult {
        guard let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AnalysisError.invalidResult
        }

        return AnalysisResult(
            overallScore: Self.intValue(object["overallScore"]),
            answerQualityScore: Self.intValue(object["answerQualityScore"]),
            clarityScore: Self.intValue(object["clarityScore"]),
            confidenceScore: Self.intValue(object["confidenceScore"]),
            communicationScore: Self.intValue(object["communicationScore"]),
            interviewSkillsScore: Self.intValue(object["interviewSkillsScore"]),
            strengths: object["strengths"] as? [String] ?? [],
            areasToImprove: object["areasToImprove"] as? [String] ?? [],
            assignedGoals: object["assignedGoals"] as? [String] ?? [],
            summary: object["summary"] as? String ?? ""
        )
    }

    private static func intValue(_ value: Any?) -> Int {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double.rounded()) }
        return 0
    }

    private var analysisSchema: [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "overallScore": scoreSchema,
                "answerQualityScore": scoreSchema,
                "clarityScore": scoreSchema,
                "confidenceScore": scoreSchema,
                "communicationScore": scoreSchema,
                "interviewSkillsScore": scoreSchema,
                "strengths": stringArraySchema(maxItems: 4),
                "areasToImprove": stringArraySchema(maxItems: 4),
                "assignedGoals": goalArraySchema,
                "summary": ["type": "string"]
            ],
            "required": [
                "overallScore",
                "answerQualityScore",
                "clarityScore",
                "confidenceScore",
                "communicationScore",
                "interviewSkillsScore",
                "strengths",
                "areasToImprove",
                "assignedGoals",
                "summary"
            ]
        ]
    }

    private var scoreSchema: [String: Any] {
        ["type": "integer", "minimum": 0, "maximum": 100]
    }

    private var goalArraySchema: [String: Any] {
        [
            "type": "array",
            "items": ["type": "string"],
            "minItems": 0,
            "maxItems": 3
        ]
    }

    private func stringArraySchema(maxItems: Int) -> [String: Any] {
        [
            "type": "array",
            "items": ["type": "string"],
            "minItems": 0,
            "maxItems": maxItems
        ]
    }
}

private enum AnalysisError: Error {
    case requestFailed
    case invalidResult
}

private extension String {
    var analysisNilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
