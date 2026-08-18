//
//  OpenAIAnalysisService.swift
//  StepIN
//
//  Production analysis service. Keeps the existing Results UI contract while
//  enforcing evidence-backed feedback rules from the authoritative prompt.
//

import Foundation

private enum AnalysisOutputLanguage: String {
    case english = "English"
    case arabic = "Arabic"

    static var current: AnalysisOutputLanguage {
        AnalysisOutputLanguage(locale: .autoupdatingCurrent)
    }

    init(locale: Locale) {
        let languageCode = locale.language.languageCode?.identifier.lowercased() ?? "en"
        self = languageCode.hasPrefix("ar") ? .arabic : .english
    }

    var analysisInstruction: String {
        switch self {
        case .english:
            return "- Generate all user-facing analysis content in English. Return the required JSON structure unchanged."
        case .arabic:
            return "- Generate all user-facing analysis content in natural professional Arabic appropriate for interview coaching. This includes strengths, areas to improve, assigned goals, and any other user-facing analysis text. Return the required JSON structure unchanged."
        }
    }
}

@MainActor
final class OpenAIAnalysisService: InterviewAnalysisServiceProtocol {
    private let apiKey: String
    private let model = "gpt-5-mini"
    private let requestTimeout: TimeInterval = 45

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func analyze(
        configuration: InterviewConfiguration,
        transcript: [TranscriptEntry],
        isPartial: Bool,
        completedQuestionCount: Int,
        deliveryMetrics: VoiceDeliveryMetrics
    ) async throws -> AnalysisResult {
        #if DEBUG
        let analysisT0 = Date.now
        print("[StepIN.AnalysisTiming] T0 service analysis begins")
        #endif

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let outputLanguage = AnalysisOutputLanguage.current
        let payload: [String: Any] = [
            "model": model,
            "input": [
                [
                    "role": "system",
                    "content": analysisInstructions(
                        for: configuration,
                        metrics: deliveryMetrics,
                        outputLanguage: outputLanguage
                    )
                ],
                [
                    "role": "user",
                    "content": transcriptText(
                        transcript,
                        configuration: configuration,
                        isPartial: isPartial,
                        completedQuestionCount: completedQuestionCount
                    )
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
        print("[StepIN.AnalysisTiming] T1 request serialization complete: \(Date.now.timeIntervalSince(analysisT0))s")
        print("[StepIN.AnalysisLanguage] outputLanguage=\(outputLanguage.rawValue)")
        logVoiceEvidenceSummary(transcript)
        #endif

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = requestTimeout
        sessionConfig.timeoutIntervalForResource = requestTimeout + 15
        let session = URLSession(configuration: sessionConfig)

        #if DEBUG
        print("[StepIN.AnalysisTiming] T2 request sent: \(Date.now.timeIntervalSince(analysisT0))s")
        #endif

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw AnalysisRequestError.transport(error)
        } catch {
            throw AnalysisRequestError.transport(URLError(.unknown))
        }

        #if DEBUG
        print("[StepIN.AnalysisTiming] T3 response received: \(Date.now.timeIntervalSince(analysisT0))s")
        #endif

        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode
            throw AnalysisRequestError.httpStatus(status)
        }

        let text = try extractOutputText(from: data)
        #if DEBUG
        print("[StepIN.AnalysisTiming] T4 JSON extracted: \(Date.now.timeIntervalSince(analysisT0))s")
        #endif

        let result = try decodeAnalysisResult(from: text)
        guard result.isValid else { throw AnalysisRequestError.invalidResult }
        logVoiceUsage(result)

        #if DEBUG
        print("[StepIN.AnalysisTiming] T5 decoded/validated: \(Date.now.timeIntervalSince(analysisT0))s")
        #endif

        return result
    }

    private func analysisInstructions(
        for configuration: InterviewConfiguration,
        metrics: VoiceDeliveryMetrics,
        outputLanguage: AnalysisOutputLanguage
    ) -> String {
        var instructions = coreAnalysisInstructions(for: configuration, outputLanguage: outputLanguage)
        if let deliveryBlock = deliveryEvidenceBlock(from: metrics) {
            instructions += "\n\n" + deliveryBlock
        }
        return instructions
    }

    private func coreAnalysisInstructions(
        for configuration: InterviewConfiguration,
        outputLanguage: AnalysisOutputLanguage
    ) -> String {
        """
        You are StepIN's interview evaluator. Return only the requested JSON object that matches the schema.

        Evaluation context:
        - Job Title: \(configuration.jobTitle)
        - Company: \(configuration.company?.analysisNilIfBlank ?? "Not provided")
        \(analysisContextLines(for: configuration))
        - Selected counted question budget: \(configuration.questionCount.rawValue)

        Output language rules:
        \(outputLanguage.analysisInstruction)
        - Keep the JSON schema, JSON keys, Codable property names, enum raw values, IDs, and all structural values exactly as required by the schema.
        - Only localize user-facing string values, including strengths, areasToImprove, assignedGoals, and any other feedback text.
        - Do not translate transcript quotes, job titles, company names, project names, product names, technologies, model names, or proper nouns unless a natural localized name is already present.

        Evidence rules:
        - Use only evidence from the provided setup data and transcript.
        - Never invent candidate facts, experience, projects, skills, certificates, achievements, responsibilities, metrics, motivations, or gaps.
        - Exclude the greeting, brief acknowledgements, clarification prompts, and final closing question from direct scoring.
        - If the interview is Partial, evaluate only completed evidence. Do not score future unanswered questions as zero.
        - If the candidate skipped or refused a counted question, score that answered item as zero evidence for that question.
        - Do not penalize untested capabilities. Treat unobserved dimensions as insufficient evidence, not weaknesses.
        - Prefer recurring patterns over isolated mistakes.
        - The CV provides context for interview questions only. Skills, projects, experience, and certifications listed on the CV do not constitute performance evidence and must not generate scores, strengths, weaknesses, or goals. Only the candidate's actual spoken answers in the transcript are performance evidence.
        - Distinguish transcript facts from performance qualities. A bare fact such as "collected and labeled dataset" is not a Strength. A Strength must evaluate how well the candidate communicated, reasoned, showed ownership, gave evidence, adapted, quantified impact, aligned with the role, or handled the interview.
        - Off-topic, non-answer, nonsense, filler-only, or refusal turns are interview-performance evidence. Repeated unrelated answers should reduce relevance, communication, answer quality, and interview skills. Do not over-penalize a single brief playful aside if the rest of the interview is strong.

        Scoring rules:
        - overallScore must be 0-100 and reflect general performance across dimensions actually observed.
        - Provide scores for the existing five UI fields: answerQualityScore, clarityScore, confidenceScore, communicationScore, and interviewSkillsScore.
        - Adapt the meaning and weighting of those scores to the Job Title, actual interview coverage, CV, job description, and observed answers.
        - Do not make every dimension equal weight by default. Redistribute emphasis across observed dimensions.
        - For confidence, combine answer content with reliable delivery evidence from the transcript when available, but do not infer internal emotional state.
        - Answer relevance, completeness, specificity, and interview participation must affect scores. CV/JD fit alone must not produce a high score.
        - No meaningful candidate participation should result in very low scores, not a normal partial-interview score.

        Feedback rules:
        - Strengths: target 4, return fewer when evidence is insufficient. Each must express one clear evidence-backed performance strength in specific, natural language.
        - Strengths should usually be 6-12 words. Do not compress to a short label. Two lines are acceptable when they add clarity; padding is not.
        - Each strength must be grounded in the candidate's actual interview answers, not CV content alone.
        - Avoid opening filler such as "Demonstrates", "Shows the ability to", "Has the capability to", or "Provides evidence of". Write the strength directly.
        - Areas to Improve: up to 4. Each must identify one evidence-backed improvement area clearly and directly.
        - Areas should usually be 6-12 words. Do not compress to a vague label. Two lines are acceptable when they add specificity; padding is not.
        - Avoid opener filler such as "Would benefit from", "Could improve by", "In future interviews", "Consider working on", or "Try to".
        - Areas to Improve should name the interview-performance issue, such as unclear individual contribution, weak specificity, missing validation method, unclear structure, off-topic response, limited relevance, unquantified impact, or less steady delivery during difficult answers.
        - Goals: up to 3. Each goal must derive directly from a supported Area to Improve and be specific, achievable, and connected to this interview.
        - Each goal string must be one short, meaningful action statement that answers only: "What should this candidate improve?"
        - Prefer 5-9 words. Never exceed 10 words.
        - Write goals for a one-line card target on a normal iPhone width.
        - Never include examples in parentheses, explanations, subtitles, paragraphs, checklists, implementation instructions, or mini coaching plans.
        - Never combine two improvement goals with "and" unless they are inseparable.
        - Do not make goals so short that they become generic labels like "Improve teamwork", "Improve ML", or "Be concise".
        - Do not start goals with "For future interviews", "You should", "Try to", "Adopt and practice", or "Prepare a concise".
        - Do not add unsupported strengths, weaknesses, or goals to fill UI space.
        - STAR is not the default recommendation. Use STAR or situation-task-action-result language only when the evidence specifically shows a behavioral or situational answer needs clearer story structure.
        - Do not recommend STAR for technical knowledge, ML knowledge, iOS knowledge, design reasoning, architecture, problem solving, confidence, concise answers, CV clarity, tool knowledge, decision-making, company motivation, or domain knowledge unless the actual weakness is behavioral story structure.
        - For technical or role-specific weaknesses, make the goal directly address the real gap, such as explaining decisions, trade-offs, outcomes, implementation reasoning, research methods, or domain concepts more clearly.
        - Return summary as an empty string.

        Internal evidence model:
        - The transcript may include per-answer evidence lines with relevance, completeness, specificity, structure, CV/JD relevance, and voice evidence.
        - Treat these lines as approximate signals to consider contextually, not ground truth. A short answer can still be strong if it directly answers the question; a long answer can still be weak if it is vague, irrelevant, or unsupported.
        - Exact CV/JD keyword overlap is only one clue. Recognize semantic alignment when the candidate discusses the same requirement, project, skill, or responsibility using different wording.
        - Use those evidence lines to improve consistency, but never expose the internal labels, raw metadata, hidden weights, or evidence model to the user.

        Voice classification evidence (per-answer, when present in transcript):
        - Each candidate response may include a structured [Voice evidence ...] line with question context, safe delivery wording, raw label, and confidence tier.
        - This is on-device Core ML evidence of vocal delivery during that answer. Voice delivery is an independent evaluation dimension, not merely a restatement of answer content.
        - Reliable voice evidence can independently create one Strength or Area to Improve when it is useful and contextually tied to a meaningful answer.
        - A technically good answer can still have a delivery Area to Improve; a basic answer can still show a calm, steady delivery Strength.
        - Use high-confidence evidence strongly when it fits the answer context. Use medium-confidence evidence only as support. Ignore low-confidence evidence.
        - Connect delivery observations to what the candidate was discussing: "maintained a calm delivery while explaining your project approach" rather than the generic "You were calm."
        - When most answers share the same classification, recognize the overall pattern: "maintained a composed delivery throughout the interview."
        - When one answer differs substantially from the others, note it contextually: "delivery became less steady while discussing a more complex topic."
        - Never mention Core ML, the raw classification label name, or the confidence percentage in user-facing feedback.
        - Never infer anxiety, stress, nervousness, or any psychological or medical state from voice data.
        - Use observable coaching language only: "maintained a calm, composed delivery", "sounded steady", "delivery became less controlled", "could benefit from pausing before complex questions".
        - Only produce a voice-delivery Strength or Area to Improve when the evidence is meaningful and useful. Do not force delivery feedback simply because voice data is present.
        - Do not let voice dominate the whole result. Balance it with content quality, specificity, ownership, role alignment, relevance, structure, and communication.
        - Never expose internal notes, evidence IDs, coverage maps, hidden weights, raw voice statistics, chain-of-thought, or internal reasoning.
        """
    }

    private func analysisContextLines(for configuration: InterviewConfiguration) -> String {
        let context = InterviewContext(configuration: configuration)
        var lines: [String] = []
        if let jd = compactContext(
            label: "Job Description",
            rawText: configuration.jobDescription,
            anchors: context.jdAnchors
        ) {
            lines.append(jd)
        } else {
            lines.append("- Job Description: Not provided")
        }
        if let cv = compactContext(
            label: "CV",
            rawText: configuration.resolvedCVText,
            anchors: context.cvAnchors
        ) {
            lines.append(cv)
        } else {
            lines.append("- CV: Not provided")
        }
        return lines.joined(separator: "\n")
    }

    private func compactContext(label: String, rawText: String?, anchors: [InterviewAnchor]) -> String? {
        guard rawText?.analysisNilIfBlank != nil || !anchors.isEmpty else { return nil }
        if !anchors.isEmpty {
            let anchorText = anchors.prefix(8).map { "\($0.kind.rawValue): \($0.title) — \($0.detail)" }
            return "- \(label) relevant anchors:\n  - " + anchorText.joined(separator: "\n  - ")
        }

        guard let rawText = rawText?.analysisNilIfBlank else { return nil }
        return "- \(label) excerpt: \(String(rawText.prefix(1_500)))"
    }

    /// Builds a delivery evidence block when sufficient on-device audio data exists.
    /// Returns nil when there is not enough candidate speech to derive useful signals.
    private func deliveryEvidenceBlock(from metrics: VoiceDeliveryMetrics) -> String? {
        #if DEBUG
        print("[VoiceAnalytics] deliveryBlock: hasEnoughEvidence=\(metrics.hasEnoughEvidence) answeredTurns=\(metrics.answeredTurnCount) speakingSeconds=\(Int(metrics.totalSpeakingSeconds))s fillerCount=\(metrics.fillerWordCount)")
        #endif
        guard metrics.hasEnoughEvidence else { return nil }

        var lines = [
            "Voice delivery evidence (on-device measurements — observable signals only, not psychological state):"
        ]

        let speakingMin = Int(metrics.totalSpeakingSeconds / 60)
        let speakingSec = Int(metrics.totalSpeakingSeconds.truncatingRemainder(dividingBy: 60))
        let durationLabel = speakingMin > 0 ? "\(speakingMin)m \(speakingSec)s" : "\(speakingSec)s"
        lines.append("- Candidate speaking time: \(durationLabel)")
        lines.append("- Speaking/silence ratio: \(Int(metrics.speakingRatio * 100))% speaking")
        lines.append("- Meaningful pauses (>1.5 s): \(metrics.pauseCount)")

        if metrics.pauseCount > 0 {
            lines.append("- Average pause: \(String(format: "%.1f", metrics.averagePauseDurationMs / 1_000))s")
            lines.append("- Longest pause: \(String(format: "%.1f", metrics.longestPauseDurationMs / 1_000))s")
        }

        if metrics.fillerWordCount >= 3 {
            lines.append("- Detected filler-word occurrences: \(metrics.fillerWordCount)")
        }

        lines += [
            "",
            "Delivery feedback rules:",
            "- Use delivery signals only as supporting communication evidence. Answer content and reasoning remain primary.",
            "- Describe observable delivery behavior, never psychological state. Do not say the candidate was nervous, anxious, stressed, or unconfident.",
            "- A delivery Strength or Area to Improve should appear only when the signal is clear, significant, and useful for the candidate.",
            "- Natural thinking pauses are not a weakness. Only flag pause patterns that clearly affect communication flow.",
            "- Filler words are supporting context, not automatic weaknesses — only mention if the count is high relative to answer length.",
            "- Do not generate a delivery Strength or Area simply because a metric exists. Significance matters.",
            "- Delivery feedback must follow the same 6–12 word target length and direct style as all other Strengths and Areas."
        ]

        return lines.joined(separator: "\n")
    }

    private func transcriptText(
        _ transcript: [TranscriptEntry],
        configuration: InterviewConfiguration,
        isPartial: Bool,
        completedQuestionCount: Int
    ) -> String {
        var latestQuestion = "No preceding interviewer question captured"
        var answerIndex = 0
        let compactedTranscript = compactTranscript(transcript)
        let lines = compactedTranscript.flatMap { entry -> [String] in
            let speaker = entry.speaker == .candidate ? "Candidate" : "AI Interviewer"
            var parts = ["\(speaker): \(entry.text)"]
            if entry.speaker == .interviewer {
                latestQuestion = entry.text
            }
            if entry.speaker == .candidate,
               entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                answerIndex += 1
                parts.append("  [Answer evidence \(answerIndex): question context: \(latestQuestion)]")
                parts.append("  [Answer evidence \(answerIndex): relevance: \(AnswerRelevanceClassifier.classify(entry.text).rawValue)]")
                parts.append("  [Answer evidence \(answerIndex): heuristic completeness signal: \(Self.completenessLabel(for: entry.text)); specificity signal: \(Self.specificityLabel(for: entry.text)); structure signal: \(Self.structureLabel(for: entry.text))]")
                parts.append("  [Answer evidence \(answerIndex): approximate CV/JD lexical signal: \(Self.contextRelevanceLabel(answer: entry.text, configuration: configuration)); also judge semantic relevance from the question context and answer]")
                if let voice = entry.voiceResult {
                    #if DEBUG
                    let voicePct = Int((voice.confidence * 100).rounded())
                    print("[VoiceAnalytics] answer\(answerIndex): label=\(voice.label) confidence=\(voicePct)% included=\(voice.confidence >= 0.55)")
                    #endif
                    if voice.confidence >= 0.55 {
                        let pct = Int((voice.confidence * 100).rounded())
                        parts.append("  [Voice evidence \(answerIndex): question topic: \(Self.shortQuestionTopic(latestQuestion)); safe delivery signal: \(Self.safeVoiceSignal(for: voice.label)); raw label: \(voice.label); confidence \(pct)% (\(Self.voiceConfidenceTier(voice.confidence)))]")
                    }
                }
            }
            return parts
        }.joined(separator: "\n")

        return """
        Interview status: \(isPartial ? "Partial" : "Completed")
        Completed counted questions: \(completedQuestionCount)

        Transcript:
        \(lines)
        """
    }

    private func compactTranscript(_ transcript: [TranscriptEntry]) -> [TranscriptEntry] {
        var compacted: [TranscriptEntry] = []
        let nonSubstantiveAssistantLines = [
            "take your time",
            "i see",
            "got it",
            "understood",
            "that makes sense",
            "interesting",
            "right",
            "fair enough"
        ]

        for entry in transcript {
            let trimmed = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if compacted.last?.speaker == entry.speaker,
               compacted.last?.text.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed {
                continue
            }
            if entry.speaker == .interviewer {
                let normalized = trimmed.lowercased().trimmingCharacters(in: .punctuationCharacters)
                if nonSubstantiveAssistantLines.contains(normalized) {
                    continue
                }
                if trimmed == "Thank you. That concludes our interview.",
                   compacted.contains(where: { $0.speaker == .interviewer && $0.text == trimmed }) {
                    continue
                }
            }
            compacted.append(entry)
        }
        return compacted
    }

    private static func completenessLabel(for text: String) -> String {
        let wordCount = text.split(separator: " ").count
        if wordCount < 6 { return "very limited" }
        if wordCount < 20 { return "partial" }
        return "substantive"
    }

    private static func specificityLabel(for text: String) -> String {
        let lower = text.lowercased()
        let specificitySignals = ["because", "for example", "result", "impact", "measured", "tested", "validated", "led", "built", "designed", "implemented", "decided", "%", "users", "customers"]
        let count = specificitySignals.reduce(0) { $0 + (lower.contains($1) ? 1 : 0) }
        if count >= 3 { return "specific" }
        if count >= 1 { return "some specifics" }
        return "generic"
    }

    private static func structureLabel(for text: String) -> String {
        let lower = text.lowercased()
        let structureSignals = ["first", "then", "after that", "because", "so", "the result", "finally", "what i did"]
        return structureSignals.contains { lower.contains($0) } ? "structured" : "unclear or unstructured"
    }

    private static func contextRelevanceLabel(answer: String, configuration: InterviewConfiguration) -> String {
        let answerWords = Set(answer.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 3 })
        let cvWords = Set((configuration.resolvedCVText ?? "").lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 3 })
        let jdWords = Set((configuration.jobDescription ?? "").lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 3 })
        let cvOverlap = !answerWords.isDisjoint(with: cvWords)
        let jdOverlap = !answerWords.isDisjoint(with: jdWords)
        if cvOverlap && jdOverlap { return "CV and JD related" }
        if cvOverlap { return "CV related" }
        if jdOverlap { return "JD related" }
        return "general or not context-grounded"
    }

    private static func shortQuestionTopic(_ question: String) -> String {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "uncaptured question topic" }
        if trimmed.count <= 120 { return trimmed }
        return String(trimmed.prefix(117)) + "..."
    }

    private static func safeVoiceSignal(for label: String) -> String {
        let normalized = label.lowercased()
        if normalized.contains("calm") {
            return "calm, steady delivery"
        }
        if normalized.contains("neutral") {
            return "controlled, neutral delivery"
        }
        if normalized.contains("fear") || normalized.contains("fearful") {
            return "less steady or hesitant delivery"
        }
        return "observable delivery variation"
    }

    private static func voiceConfidenceTier(_ confidence: Double) -> String {
        if confidence >= 0.75 { return "high" }
        if confidence >= 0.60 { return "medium" }
        return "low-supporting"
    }

    private func logVoiceEvidenceSummary(_ transcript: [TranscriptEntry]) {
        #if DEBUG
        let candidateEntries = transcript.filter { $0.speaker == .candidate }
        let voiceEntries = candidateEntries.compactMap(\.voiceResult)
        let highConfidence = voiceEntries.filter { $0.confidence >= 0.75 }.count
        print("[AnalysisVoiceEvidence] candidateTurns=\(candidateEntries.count) turnsWithVoiceEvidence=\(voiceEntries.count) highConfidenceVoiceTurns=\(highConfidence)")
        #endif
    }

    private func logVoiceUsage(_ result: AnalysisResult) {
        #if DEBUG
        let deliveryMarkers = ["delivery", "steady", "calm", "composed", "controlled", "hesitant", "rushed", "pause", "pacing"]
        let strengthsWithVoice = result.strengths.filter { item in
            deliveryMarkers.contains { item.localizedCaseInsensitiveContains($0) }
        }.count
        let areasWithVoice = result.areasToImprove.filter { item in
            deliveryMarkers.contains { item.localizedCaseInsensitiveContains($0) }
        }.count
        print("[AnalysisVoiceUsage] strengthsContainingVoiceEvidence=\(strengthsWithVoice) areasContainingVoiceEvidence=\(areasWithVoice)")
        #endif
    }

    private func extractOutputText(from data: Data) throws -> String {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AnalysisRequestError.invalidResult
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

        throw AnalysisRequestError.invalidResult
    }

    private func decodeAnalysisResult(from text: String) throws -> AnalysisResult {
        guard let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AnalysisRequestError.invalidResult
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

enum AnalysisRequestError: Error {
    case transport(URLError)
    case httpStatus(Int?)
    case invalidResult

    var isRetryable: Bool {
        switch self {
        case .transport(let error):
            return [
                .timedOut,
                .cannotFindHost,
                .cannotConnectToHost,
                .networkConnectionLost,
                .notConnectedToInternet,
                .dnsLookupFailed
            ].contains(error.code)
        case .httpStatus(let status):
            guard let status else { return false }
            return status == 408 || status == 429 || (500...599).contains(status)
        case .invalidResult:
            return false
        }
    }
}

private extension String {
    var analysisNilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
